Attribute VB_Name = "MI_Set_Tablespaces"
Option Explicit

' Массовая нормализация tablespace в физической модели erwin.
' Работает через erwin Script Client API (SCAPI), без правки XML/DDL.

Private Const TABLE_TABLESPACE As String = "USERS"
Private Const INDEX_TABLESPACE As String = "INDEXES"
Private Const TABLE_PREFIX As String = "MI_"

' PK этих IOT является самим табличным сегментом и должен остаться в USERS.
Private Const IOT_TABLES As String = "|MI_P2A|MI_P2I|"

Private g_Log As Object
Private g_TableStorageChanged As Long
Private g_IndexStorageChanged As Long
Private g_PartitionStorageChanged As Long
Private g_ObjectsCreated As Long
Private g_Skipped As Long

Public Sub MI_Tablespaces_Dry_Run()
   RunTablespaceUpdate False
End Sub

Public Sub MI_Tablespaces_Apply()
   RunTablespaceUpdate True
End Sub

Private Sub RunTablespaceUpdate(ByVal applyChanges As Boolean)
   Dim selectedFile As Variant
   Dim modelPath As String
   Dim modelUri As String
   Dim logPath As String
   Dim backupPath As String
   Dim erwinApp As Object
   Dim persistenceUnit As Object
   Dim session As Object
   Dim tableTs As Object
   Dim indexTs As Object
   Dim transactionId As Variant
   Dim transactionOpen As Boolean
   Dim errorNumber As Long
   Dim errorDescription As String

   On Error GoTo Failed

   selectedFile = Application.GetOpenFilename( _
      "erwin models (*.erwin),*.erwin", , _
      "Выберите физическую модель Oracle MI")

   If VarType(selectedFile) = vbBoolean Then Exit Sub

   modelPath = CStr(selectedFile)
   modelUri = "erwin://" & modelPath
   logPath = modelPath & ".tablespaces.log"

   OpenLog logPath
   ResetCounters

   WriteLog "Режим: " & IIf(applyChanges, "APPLY", "DRY_RUN")
   WriteLog "Модель: " & modelPath
   WriteLog "Таблицы: " & TABLE_TABLESPACE
   WriteLog "Индексы: " & INDEX_TABLESPACE
   WriteLog String$(72, "-")

   If applyChanges Then
      backupPath = BuildBackupPath(modelPath)
      FileCopy modelPath, backupPath
      WriteLog "Резервная копия: " & backupPath
   End If

   Set erwinApp = CreateErwinApplication()
   If erwinApp Is Nothing Then
      Err.Raise vbObjectError + 1000, , _
         "Не удалось создать erwin SCAPI.Application. " & _
         "Проверьте регистрацию EAL.dll и разрядность Excel/erwin."
   End If

   Set persistenceUnit = erwinApp.PersistenceUnits.Add( _
      modelUri, IIf(applyChanges, "RDO=No", "RDO=Yes"))
   Set session = erwinApp.Sessions.Add
   session.Open persistenceUnit

   Set tableTs = FindTablespace(session, TABLE_TABLESPACE)
   Set indexTs = FindTablespace(session, INDEX_TABLESPACE)

   If tableTs Is Nothing Then
      Err.Raise vbObjectError + 1001, , _
         "В модели не найден Oracle tablespace " & TABLE_TABLESPACE
   End If

   If indexTs Is Nothing Then
      Err.Raise vbObjectError + 1002, , _
         "В модели не найден Oracle tablespace " & INDEX_TABLESPACE
   End If

   If applyChanges Then
      transactionId = session.BeginNamedTransaction( _
         "MI: normalize USERS/INDEXES")
      transactionOpen = True
   End If

   NormalizeTables session, tableTs, applyChanges
   NormalizeIndexes session, tableTs, indexTs, applyChanges
   NormalizePartitionStorage session, tableTs, indexTs, applyChanges

   If applyChanges Then
      session.CommitTransaction transactionId
      transactionOpen = False

      ' Commit меняет модель в памяти; Save сохраняет файл.
      persistenceUnit.Save
   End If

   WriteSummary applyChanges

CleanUp:
   On Error Resume Next

   If Not session Is Nothing Then session.Close
   If Not erwinApp Is Nothing Then erwinApp.Sessions.Clear
   If Not erwinApp Is Nothing Then erwinApp.PersistenceUnits.Clear

   Set tableTs = Nothing
   Set indexTs = Nothing
   Set session = Nothing
   Set persistenceUnit = Nothing
   Set erwinApp = Nothing

   CloseLog

   If errorNumber <> 0 Then
      MsgBox "Обработка модели завершилась с ошибкой:" & vbCrLf & _
         errorDescription & vbCrLf & vbCrLf & _
         "Диагностика: " & logPath, vbCritical
   Else
      MsgBox IIf(applyChanges, _
         "Tablespace сохранены в модели.", _
         "Проверка завершена, модель не изменялась.") & _
         vbCrLf & "Отчёт: " & logPath, vbInformation
   End If

   Exit Sub

Failed:
   errorNumber = Err.Number
   errorDescription = Err.Description
   WriteLog "ОШИБКА " & CStr(errorNumber) & ": " & errorDescription

   On Error Resume Next
   If transactionOpen Then
      session.RollbackTransaction transactionId
      transactionOpen = False
   End If
   On Error GoTo 0

   GoTo CleanUp
End Sub

Private Sub NormalizeTables( _
   ByVal session As Object, _
   ByVal tableTs As Object, _
   ByVal applyChanges As Boolean)

   Dim entities As Object
   Dim entity As Object
   Dim tableName As String
   Dim storages As Object
   Dim storage As Object
   Dim directStorageCount As Long
   Dim storageRefProperty As String

   Set entities = session.ModelObjects.Collect( _
      session.ModelObjects.Root, "Entity")

   For Each entity In entities
      tableName = PhysicalName(entity)

      If IsTargetEntity(entity, tableName) Then
         directStorageCount = 0
         Set storages = session.ModelObjects.Collect( _
            entity, "Oracle_Physical_Storage")

         For Each storage In storages
            If IsDirectChild(storage, entity) Then
               directStorageCount = directStorageCount + 1
               SetReference storage, "Oracle_Tablespace_Ref", _
                  tableTs, "TABLE " & tableName, _
                  applyChanges, g_TableStorageChanged
            End If
         Next storage

         If directStorageCount = 0 Then
            If IsIotTable(tableName) Then
               storageRefProperty = "Oracle_Index_Storage_Ref"
            Else
               storageRefProperty = "Oracle_Regular_Storage_Ref"
            End If

            WriteLog ActionPrefix(applyChanges) & _
               " создать Oracle_Physical_Storage: TABLE " & tableName

            If applyChanges Then
               Set storage = session.ModelObjects.Collect(entity).Add( _
                  "Oracle_Physical_Storage")
               storage.Properties("Oracle_Tablespace_Ref").Value = _
                  tableTs.ObjectId
               entity.Properties(storageRefProperty).Value = storage.ObjectId
            End If

            g_ObjectsCreated = g_ObjectsCreated + 1
            g_TableStorageChanged = g_TableStorageChanged + 1
         End If
      End If
   Next entity
End Sub

Private Sub NormalizeIndexes( _
   ByVal session As Object, _
   ByVal tableTs As Object, _
   ByVal indexTs As Object, _
   ByVal applyChanges As Boolean)

   Dim keyGroups As Object
   Dim keyGroup As Object
   Dim owner As Object
   Dim indexStorageObjects As Object
   Dim indexStorage As Object
   Dim physicalStorageObjects As Object
   Dim physicalStorage As Object
   Dim tableName As String
   Dim indexName As String
   Dim directStorageCount As Long

   Set keyGroups = session.ModelObjects.Collect( _
      session.ModelObjects.Root, "Key_Group")

   For Each keyGroup In keyGroups
      Set owner = keyGroup.Context

      If Not owner Is Nothing Then
         If owner.ClassName = "Entity" Then
            tableName = PhysicalName(owner)
            indexName = PhysicalName(keyGroup)

            If IsTargetEntity(owner, tableName) Then
               If IsIotPrimaryIndex(keyGroup, tableName, indexName) Then
                  WriteLog "SKIP IOT PK: " & tableName & "." & indexName & _
                     " (табличный сегмент остаётся в " & _
                     TABLE_TABLESPACE & ")"
                  g_Skipped = g_Skipped + 1
               Else
                  directStorageCount = 0
                  Set indexStorageObjects = session.ModelObjects.Collect( _
                     keyGroup, "Oracle_Attribute_Storage")

                  For Each indexStorage In indexStorageObjects
                     If IsDirectChild(indexStorage, keyGroup) Then
                        directStorageCount = directStorageCount + 1
                        SetReference indexStorage, _
                           "Oracle_Tablespace_Ref", indexTs, _
                           "INDEX " & tableName & "." & indexName, _
                           applyChanges, g_IndexStorageChanged

                        ' В разных версиях erwin часть storage-параметров
                        ' может находиться во вложенном объекте.
                        Set physicalStorageObjects = _
                           session.ModelObjects.Collect( _
                              indexStorage, "Oracle_Physical_Storage")

                        For Each physicalStorage In physicalStorageObjects
                           If IsDirectChild(physicalStorage, indexStorage) Then
                              SetReference physicalStorage, _
                                 "Oracle_Tablespace_Ref", indexTs, _
                                 "INDEX STORAGE " & tableName & "." & _
                                    indexName, _
                                 applyChanges, g_IndexStorageChanged
                           End If
                        Next physicalStorage
                     End If
                  Next indexStorage

                  If directStorageCount = 0 Then
                     WriteLog ActionPrefix(applyChanges) & _
                        " создать Oracle_Attribute_Storage: INDEX " & _
                        tableName & "." & indexName

                     If applyChanges Then
                        Set indexStorage = _
                           session.ModelObjects.Collect(keyGroup).Add( _
                              "Oracle_Attribute_Storage")
                        indexStorage.Properties( _
                           "Oracle_Tablespace_Ref").Value = indexTs.ObjectId
                     End If

                     g_ObjectsCreated = g_ObjectsCreated + 1
                     g_IndexStorageChanged = g_IndexStorageChanged + 1
                  End If
               End If
            End If
         End If
      End If
   Next keyGroup
End Sub

Private Sub NormalizePartitionStorage( _
   ByVal session As Object, _
   ByVal tableTs As Object, _
   ByVal indexTs As Object, _
   ByVal applyChanges As Boolean)

   Dim partitionStorageObjects As Object
   Dim partitionStorage As Object
   Dim entity As Object
   Dim keyGroup As Object
   Dim targetTs As Object
   Dim objectLabel As String

   Set partitionStorageObjects = session.ModelObjects.Collect( _
      session.ModelObjects.Root, "Oracle_Partitioning_Storage")

   For Each partitionStorage In partitionStorageObjects
      Set entity = FindAncestor(partitionStorage, "Entity")

      If Not entity Is Nothing Then
         If IsTargetEntity(entity, PhysicalName(entity)) Then
            Set keyGroup = FindAncestor(partitionStorage, "Key_Group")

            If keyGroup Is Nothing Then
               Set targetTs = tableTs
               objectLabel = "TABLE PARTITION " & PhysicalName(entity)
            Else
               Set targetTs = indexTs
               objectLabel = "INDEX PARTITION " & PhysicalName(entity) & _
                  "." & PhysicalName(keyGroup)
            End If

            SetReference partitionStorage, "Oracle_Tablespace_Ref", _
               targetTs, objectLabel, applyChanges, _
               g_PartitionStorageChanged

            If partitionStorage.Properties.HasProperty( _
               "Oracle_Overflow_Tablespace_Ref") Then
               SetReference partitionStorage, _
                  "Oracle_Overflow_Tablespace_Ref", tableTs, _
                  objectLabel & " OVERFLOW", applyChanges, _
                  g_PartitionStorageChanged
            End If
         End If
      End If
   Next partitionStorage
End Sub

Private Sub SetReference( _
   ByVal modelObject As Object, _
   ByVal propertyName As String, _
   ByVal targetObject As Object, _
   ByVal objectLabel As String, _
   ByVal applyChanges As Boolean, _
   ByRef changedCounter As Long)

   Dim currentId As String

   currentId = ReferenceValue(modelObject, propertyName)

   If StrComp(currentId, CStr(targetObject.ObjectId), _
      vbTextCompare) <> 0 Then

      WriteLog ActionPrefix(applyChanges) & " " & objectLabel & _
         " -> " & PropertyText(targetObject, "Name")

      If applyChanges Then
         modelObject.Properties(propertyName).Value = targetObject.ObjectId
      End If

      changedCounter = changedCounter + 1
   End If
End Sub

Private Function FindTablespace( _
   ByVal session As Object, _
   ByVal tablespaceName As String) As Object

   Dim tablespaces As Object
   Dim tablespace As Object
   Dim candidateName As String

   Set tablespaces = session.ModelObjects.Collect( _
      session.ModelObjects.Root, "Oracle_Tablespace")

   For Each tablespace In tablespaces
      candidateName = PropertyText(tablespace, "Name")

      If StrComp(candidateName, tablespaceName, _
         vbTextCompare) = 0 Then
         Set FindTablespace = tablespace
         Exit Function
      End If
   Next tablespace
End Function

Private Function FindAncestor( _
   ByVal modelObject As Object, _
   ByVal className As String) As Object

   Dim currentObject As Object

   Set currentObject = modelObject.Context

   Do While Not currentObject Is Nothing
      If currentObject.ClassName = className Then
         Set FindAncestor = currentObject
         Exit Function
      End If

      Set currentObject = currentObject.Context
   Loop
End Function

Private Function IsTargetEntity( _
   ByVal entity As Object, _
   ByVal tableName As String) As Boolean

   If Len(tableName) = 0 Then Exit Function
   If Left$(UCase$(tableName), Len(TABLE_PREFIX)) <> TABLE_PREFIX Then _
      Exit Function

   If BooleanProperty(entity, "Is_Logical_Only", False) Then Exit Function
   If BooleanProperty(entity, "Do_Not_Generate", False) Then Exit Function

   IsTargetEntity = True
End Function

Private Function IsIotPrimaryIndex( _
   ByVal keyGroup As Object, _
   ByVal tableName As String, _
   ByVal indexName As String) As Boolean

   Dim keyGroupType As String

   If Not IsIotTable(tableName) Then Exit Function

   keyGroupType = UCase$(PropertyText(keyGroup, "Key_Group_Type"))

   If InStr(1, keyGroupType, "PRIMARY", vbTextCompare) > 0 Or _
      InStr(1, keyGroupType, "PK", vbTextCompare) > 0 Or _
      StrComp(indexName, "P_" & tableName, vbTextCompare) = 0 Then
      IsIotPrimaryIndex = True
   End If
End Function

Private Function IsIotTable(ByVal tableName As String) As Boolean
   IsIotTable = InStr(1, IOT_TABLES, _
      "|" & UCase$(tableName) & "|", vbBinaryCompare) > 0
End Function

Private Function IsDirectChild( _
   ByVal childObject As Object, _
   ByVal parentObject As Object) As Boolean

   Dim owner As Object

   Set owner = childObject.Context
   If owner Is Nothing Then Exit Function

   IsDirectChild = (StrComp(CStr(owner.ObjectId), _
      CStr(parentObject.ObjectId), vbTextCompare) = 0)
End Function

Private Function PhysicalName(ByVal modelObject As Object) As String
   PhysicalName = PropertyText(modelObject, "Physical_Name")

   If Len(PhysicalName) = 0 Then
      PhysicalName = PropertyText(modelObject, "Name")
   End If
End Function

Private Function PropertyText( _
   ByVal modelObject As Object, _
   ByVal propertyName As String) As String

   On Error GoTo NoValue

   If modelObject.Properties.HasProperty(propertyName) Then
      PropertyText = Trim$( _
         CStr(modelObject.Properties(propertyName).FormatAsString))
   End If

   Exit Function

NoValue:
   PropertyText = vbNullString
End Function

Private Function ReferenceValue( _
   ByVal modelObject As Object, _
   ByVal propertyName As String) As String

   On Error GoTo NoValue

   If modelObject.Properties.HasProperty(propertyName) Then
      ReferenceValue = CStr(modelObject.Properties(propertyName).Value)
   End If

   Exit Function

NoValue:
   ReferenceValue = vbNullString
End Function

Private Function BooleanProperty( _
   ByVal modelObject As Object, _
   ByVal propertyName As String, _
   ByVal defaultValue As Boolean) As Boolean

   On Error GoTo UseDefault

   If modelObject.Properties.HasProperty(propertyName) Then
      BooleanProperty = CBool(modelObject.Properties(propertyName).Value)
   Else
      BooleanProperty = defaultValue
   End If

   Exit Function

UseDefault:
   BooleanProperty = defaultValue
End Function

Private Function CreateErwinApplication() As Object
   Dim erwinApp As Object

   On Error Resume Next

   Set erwinApp = CreateObject("erwin9.SCAPI")
   If erwinApp Is Nothing Then
      Set erwinApp = CreateObject("ERwin9.SCAPI.9.0")
   End If
   If erwinApp Is Nothing Then
      Set erwinApp = CreateObject( _
         "AllFusionERwin.SCAPI")
   End If

   On Error GoTo 0

   Set CreateErwinApplication = erwinApp
End Function

Private Function BuildBackupPath(ByVal modelPath As String) As String
   Dim dotPosition As Long
   Dim baseName As String
   Dim extension As String

   dotPosition = InStrRev(modelPath, ".")

   If dotPosition > 0 Then
      baseName = Left$(modelPath, dotPosition - 1)
      extension = Mid$(modelPath, dotPosition)
   Else
      baseName = modelPath
      extension = vbNullString
   End If

   BuildBackupPath = baseName & ".before-tablespaces-" & _
      Format$(Now, "yyyymmdd-hhnnss") & extension
End Function

Private Function ActionPrefix(ByVal applyChanges As Boolean) As String
   ActionPrefix = IIf(applyChanges, "SET", "WOULD SET")
End Function

Private Sub ResetCounters()
   g_TableStorageChanged = 0
   g_IndexStorageChanged = 0
   g_PartitionStorageChanged = 0
   g_ObjectsCreated = 0
   g_Skipped = 0
End Sub

Private Sub WriteSummary(ByVal applyChanges As Boolean)
   WriteLog String$(72, "-")
   WriteLog "Итог: " & IIf(applyChanges, "изменения сохранены", _
      "только проверка")
   WriteLog "Table storage: " & CStr(g_TableStorageChanged)
   WriteLog "Index storage: " & CStr(g_IndexStorageChanged)
   WriteLog "Partition storage: " & CStr(g_PartitionStorageChanged)
   WriteLog "Новых storage-объектов: " & CStr(g_ObjectsCreated)
   WriteLog "Пропущено IOT PK: " & CStr(g_Skipped)
End Sub

Private Sub OpenLog(ByVal logPath As String)
   Dim fileSystem As Object

   Set fileSystem = CreateObject("Scripting.FileSystemObject")
   Set g_Log = fileSystem.CreateTextFile(logPath, True, True)
End Sub

Private Sub WriteLog(ByVal text As String)
   Debug.Print text
   If Not g_Log Is Nothing Then g_Log.WriteLine text
End Sub

Private Sub CloseLog()
   On Error Resume Next
   If Not g_Log Is Nothing Then g_Log.Close
   Set g_Log = Nothing
End Sub
