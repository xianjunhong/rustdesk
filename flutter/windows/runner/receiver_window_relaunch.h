#ifndef RUNNER_RECEIVER_WINDOW_RELAUNCH_H_
#define RUNNER_RECEIVER_WINDOW_RELAUNCH_H_

#include <windows.h>

namespace receiver_window {

bool EnableRelaunch(HWND window);
void DisableRelaunch(HWND window);
bool RestoreExistingWindow();

}  // namespace receiver_window

#endif  // RUNNER_RECEIVER_WINDOW_RELAUNCH_H_
