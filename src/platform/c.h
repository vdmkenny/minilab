/* The C interfaces the app uses, which the build translates into one Zig module: SDL3, and Dear
 * ImGui through Dear Bindings with its SDL3 and SDL_GPU backends. */
#include <SDL3/SDL.h>

#include "dcimgui.h"
#include "dcimgui_impl_sdl3.h"
#include "dcimgui_impl_sdlgpu3.h"
