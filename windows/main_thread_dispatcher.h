#ifndef XUE_HUA_MEDIA_COMPRESSION_WINDOWS_MAIN_THREAD_DISPATCHER_H_
#define XUE_HUA_MEDIA_COMPRESSION_WINDOWS_MAIN_THREAD_DISPATCHER_H_

#include <windows.h>

#include <functional>

namespace xue_hua_media_compression {

class MainThreadDispatcher {
 public:
  MainThreadDispatcher() {
    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = WndProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kClassName;
    RegisterClassW(&window_class);
    hwnd_ = CreateWindowExW(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                            nullptr, window_class.hInstance, nullptr);
  }

  ~MainThreadDispatcher() {
    if (hwnd_) {
      DestroyWindow(hwnd_);
    }
  }

  void Post(std::function<void()> task) const {
    if (!hwnd_) {
      return;
    }
    auto* heap_task = new std::function<void()>(std::move(task));
    if (!PostMessageW(hwnd_, kRunTaskMessage, 0,
                      reinterpret_cast<LPARAM>(heap_task))) {
      delete heap_task;
    }
  }

 private:
  static constexpr UINT kRunTaskMessage = WM_APP + 0x5848;
  static constexpr const wchar_t* kClassName =
      L"XueHuaMediaCompressionDispatcherWindow";

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
    if (message == kRunTaskMessage) {
      auto* task = reinterpret_cast<std::function<void()>*>(lparam);
      (*task)();
      delete task;
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  HWND hwnd_ = nullptr;
};

}  // namespace xue_hua_media_compression

#endif  // XUE_HUA_MEDIA_COMPRESSION_WINDOWS_MAIN_THREAD_DISPATCHER_H_
