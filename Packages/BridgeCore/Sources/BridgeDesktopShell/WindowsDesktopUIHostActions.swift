#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsDesktopUIHostActions {
    static func chooseProjectDirectory(
      completion: @escaping @Sendable (_ name: String, _ path: String) -> Void
    ) {
      WindowsUIThread.shared.enqueue {
        guard let path = chooseDirectory() else { return }
        let name =
          path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
          ?? path
        completion(name, path)
      }
    }

    static func chooseExecutableFile(
      title: String = "选择 Agent 可执行文件",
      completion: @escaping @Sendable (_ path: String) -> Void
    ) {
      let filter = "可执行文件 (*.exe;*.cmd;*.bat)\0*.exe;*.cmd;*.bat\0所有文件 (*.*)\0*.*\0"
      chooseFile(title: title, filter: filter, completion: completion)
    }

    static func chooseConfigFile(
      title: String = "选择 Agent 配置文件",
      completion: @escaping @Sendable (_ path: String) -> Void
    ) {
      let filter = "配置文件 (*.yml;*.yaml;*.json)\0*.yml;*.yaml;*.json\0所有文件 (*.*)\0*.*\0"
      chooseFile(title: title, filter: filter, completion: completion)
    }

    static func chooseFile(
      title: String,
      filter: String,
      completion: @escaping @Sendable (_ path: String) -> Void
    ) {
      WindowsUIThread.shared.enqueue {
        guard let path = openFileDialog(title: title, filter: filter) else { return }
        completion(path)
      }
    }

    private static func openFileDialog(title: String, filter: String) -> String? {
      // Long-path safe: 32k buffer instead of MAX_PATH 260.
      let bufferCount = 32_768
      var fileName = [WCHAR](repeating: 0, count: bufferCount)
      var filterChars = [WCHAR]()
      for char in filter.utf16 {
        filterChars.append(char)
      }
      if filterChars.last != 0 { filterChars.append(0) }
      filterChars.append(0)

      return title.withCString(encodedAs: UTF16.self) { titlePointer in
        filterChars.withUnsafeBufferPointer { filterPointer in
          fileName.withUnsafeMutableBufferPointer { filePointer in
            var ofn = OPENFILENAMEW()
            ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
            ofn.hwndOwner = WindowsMainWindow.currentWindow()
            ofn.lpstrFilter = filterPointer.baseAddress
            ofn.lpstrFile = filePointer.baseAddress
            ofn.nMaxFile = DWORD(bufferCount)
            ofn.lpstrTitle = titlePointer
            ofn.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR)
            guard GetOpenFileNameW(&ofn) else { return nil }
            return String(decoding: filePointer.prefix { $0 != 0 }, as: UTF16.self)
          }
        }
      }
    }

    // MARK: - Project directory picker (modern IFileOpenDialog + legacy fallback)

    private static func chooseDirectory() -> String? {
      ensureUIThreadCOM()
      switch chooseDirectoryModern() {
      case .selected(let path):
        return path
      case .cancelled:
        // User pressed Cancel/Esc: terminal, must NOT fall back to legacy
        // (legacy would pop a second dialog behind the first).
        return nil
      case .failed:
        return chooseDirectoryLegacy()
      }
    }

    private enum FolderPickerOutcome {
      case selected(String)
      case cancelled
      case failed
    }

    /// Ensures the Win32 UI thread is STA-initialized for Shell dialogs.
    /// The UI pump in WindowsUIThread.run() never called CoInitializeEx, so the
    /// first SHBrowseForFolder/IFileDialog here would return CO_E_NOTINITIALIZED
    /// or an empty tree. Kept for process lifetime on purpose.
    nonisolated(unsafe) private static var comInitialized: Bool = false
    private static func ensureUIThreadCOM() {
      guard !comInitialized else { return }
      // COINIT_APARTMENTTHREADED = 0x2. S_OK = 0, S_FALSE = 1.
      let hr = CoInitializeEx(nil, DWORD(0x2))
      if hr == 0 || hr == 1 {
        comInitialized = true
      } else {
        _ = OleInitialize(nil)
        comInitialized = true
      }
    }

    /// Modern picker: IFileOpenDialog with FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM.
    /// Supports long paths, search box, breadcrumb, and redirected profiles.
    /// Cancel (HRESULT_CANCELLED) is terminal; only genuine failures fall back.
    private static func chooseDirectoryModern() -> FolderPickerOutcome {
      let title = "选择要注册到 Codex Bridge 的项目目录"
      var dialog: UnsafeMutableRawPointer?
      var clsid = makeFolderPickerGUID(
        0xDC1C_5A9C, 0xE88A, 0x4DDE,
        (0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7)
      )
      var iid = makeFolderPickerGUID(
        0xD57C_7288, 0xD4AD, 0x4768,
        (0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60)
      )
      // CLSCTX_INPROC_SERVER = 1
      let hrCreate = CoCreateInstance(&clsid, nil, DWORD(1), &iid, &dialog)
      guard hrCreate == 0, let dialog else { return .failed }
      defer { folderPickerRelease(dialog) }

      // FOS_PICKFOLDERS(0x20) | FOS_FORCEFILESYSTEM(0x40) | FOS_NOCHANGEDIR(0x08)
      // | FOS_DONTADDTORECENT(0x02000000)
      let options: DWORD = DWORD(0x20) | DWORD(0x40) | DWORD(0x08) | DWORD(0x0200_0000)
      _ = folderPickerSetOptions(dialog, options)
      title.withCString(encodedAs: UTF16.self) { titlePointer in
        _ = folderPickerSetTitle(dialog, titlePointer)
      }
      if let initialDir = portableInitialDirectory(),
        let item = shellItemFromPath(initialDir)
      {
        _ = folderPickerSetDefaultFolder(dialog, item)
        folderPickerRelease(item)
      }

      let owner = WindowsMainWindow.currentWindow()
      let hrShow = folderPickerShow(dialog, owner)
      // HRESULT_FROM_WIN32(ERROR_CANCELLED=1223) = 0x800704C7: user cancelled.
      if hrShow == HRESULT(bitPattern: 0x8007_04C7) { return .cancelled }
      guard hrShow == 0 else { return .failed }
      var result: UnsafeMutableRawPointer?
      guard folderPickerGetResult(dialog, &result) == 0, let result else { return .failed }
      defer { folderPickerRelease(result) }
      guard let path = shellItemFilePath(result) else { return .failed }
      return .selected(path)
    }

    /// Legacy fallback: SHBrowseForFolderW with 32k buffer.
    /// Only reached when IFileDialog is unavailable (very old shell).
    private static func chooseDirectoryLegacy() -> String? {
      let bufferCount = 32_768
      var displayName = [WCHAR](repeating: 0, count: bufferCount)
      let title = "选择要注册到 Codex Bridge 的项目目录"
      let selected = title.withCString(encodedAs: UTF16.self) { titlePointer in
        displayName.withUnsafeMutableBufferPointer { displayPointer in
          var info = BROWSEINFOW()
          info.hwndOwner = WindowsMainWindow.currentWindow()
          info.pszDisplayName = displayPointer.baseAddress
          info.lpszTitle = titlePointer
          info.ulFlags = UINT(BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE)
          return SHBrowseForFolderW(&info)
        }
      }
      guard let selected else { return nil }
      defer { CoTaskMemFree(selected) }
      var path = [WCHAR](repeating: 0, count: bufferCount)
      guard
        path.withUnsafeMutableBufferPointer({
          SHGetPathFromIDListW(selected, $0.baseAddress)
        })
      else { return nil }
      let result = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
      return result.isEmpty ? nil : result
    }

    /// Portable-aware initial directory: prefers the redirected USERPROFILE so
    /// the dialog never opens into an empty room. Falls back to nil (shell
    /// default) when unavailable.
    private static func portableInitialDirectory() -> String? {
      let env = ProcessInfo.processInfo.environment
      let redirected = env["USERPROFILE"] ?? env["UserProfile"]
      if let redirected, !redirected.isEmpty,
        FileManager.default.fileExists(atPath: redirected)
      {
        return redirected
      }
      return nil
    }

    // MARK: - Minimal IFileDialog COM helpers (same vtable style as WebView2 ABI)

    private static func makeFolderPickerGUID(
      _ data1: UInt32,
      _ data2: UInt16,
      _ data3: UInt16,
      _ data4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    ) -> GUID {
      var guid = GUID()
      guid.Data1 = data1
      guid.Data2 = data2
      guid.Data3 = data3
      guid.Data4 = data4
      return guid
    }

    private static func folderPickerMethod<F>(
      _ object: UnsafeMutableRawPointer, _ slot: Int, as type: F.Type
    ) -> F {
      let vtable = UnsafeRawPointer(object).load(as: UnsafeRawPointer.self)
      return vtable.load(fromByteOffset: slot * MemoryLayout<UnsafeRawPointer>.size, as: F.self)
    }

    private static func folderPickerRelease(_ object: UnsafeMutableRawPointer) {
      typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
      let release: ReleaseFn = folderPickerMethod(object, 2, as: ReleaseFn.self)
      _ = release(object)
    }

    private static func folderPickerSetOptions(_ object: UnsafeMutableRawPointer, _ options: DWORD)
      -> HRESULT
    {
      typealias SetOptionsFn = @convention(c) (UnsafeMutableRawPointer?, DWORD) -> HRESULT
      let fn: SetOptionsFn = folderPickerMethod(object, 9, as: SetOptionsFn.self)
      return fn(object, options)
    }

    private static func folderPickerSetTitle(
      _ object: UnsafeMutableRawPointer, _ title: UnsafePointer<WCHAR>?
    ) -> HRESULT {
      typealias SetTitleFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<WCHAR>?)
        -> HRESULT
      let fn: SetTitleFn = folderPickerMethod(object, 17, as: SetTitleFn.self)
      return fn(object, title)
    }

    private static func folderPickerSetDefaultFolder(
      _ object: UnsafeMutableRawPointer, _ folder: UnsafeMutableRawPointer?
    ) -> HRESULT {
      typealias SetFolderFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?)
        -> HRESULT
      let fn: SetFolderFn = folderPickerMethod(object, 11, as: SetFolderFn.self)
      return fn(object, folder)
    }

    private static func folderPickerShow(_ object: UnsafeMutableRawPointer, _ owner: HWND?)
      -> HRESULT
    {
      typealias ShowFn = @convention(c) (UnsafeMutableRawPointer?, HWND?) -> HRESULT
      let fn: ShowFn = folderPickerMethod(object, 3, as: ShowFn.self)
      return fn(object, owner)
    }

    private static func folderPickerGetResult(
      _ object: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> HRESULT {
      typealias GetResultFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
      ) -> HRESULT
      let fn: GetResultFn = folderPickerMethod(object, 20, as: GetResultFn.self)
      return fn(object, out)
    }

    private static func shellItemFromPath(_ path: String) -> UnsafeMutableRawPointer? {
      // SHCreateItemFromParsingName(path, nil, IID_IShellItem, &item)
      var iid = makeFolderPickerGUID(
        0x4382_6D1E, 0xE718, 0x42EE,
        (0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE)
      )
      var item: UnsafeMutableRawPointer?
      let hr = path.withCString(encodedAs: UTF16.self) { ptr in
        SHCreateItemFromParsingName(ptr, nil, &iid, &item)
      }
      guard hr == 0 else { return nil }
      return item
    }

    private static func shellItemFilePath(_ item: UnsafeMutableRawPointer) -> String? {
      // IShellItem.GetDisplayName slot 5, SIGDN_FILESYSPATH = 0x80058000
      typealias GetDisplayNameFn = @convention(c) (
        UnsafeMutableRawPointer?, DWORD, UnsafeMutablePointer<UnsafeMutablePointer<WCHAR>?>?
      ) -> HRESULT
      let fn: GetDisplayNameFn = folderPickerMethod(item, 5, as: GetDisplayNameFn.self)
      var name: UnsafeMutablePointer<WCHAR>?
      guard fn(item, DWORD(0x8005_8000), &name) == 0, let name else { return nil }
      defer { CoTaskMemFree(name) }
      var length = 0
      while name[length] != 0 { length += 1 }
      let buffer = UnsafeBufferPointer(start: name, count: length)
      let result = String(decoding: buffer, as: UTF16.self)
      return result.isEmpty ? nil : result
    }
  }
#endif
