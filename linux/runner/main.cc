#include "my_application.h"

int main(int argc, char** argv) {
  // Flutter's software renderer aborts the moment it has to draw text
  // ("Impeller DlText cannot be drawn to a Skia canvas"), so a leftover
  // FLUTTER_LINUX_RENDERER=software would kill the app at startup. Ignore
  // that one setting and start with the default renderer instead.
  if (g_strcmp0(g_getenv("FLUTTER_LINUX_RENDERER"), "software") == 0) {
    g_printerr(
        "WeekToDo: ignoring FLUTTER_LINUX_RENDERER=software; this Flutter "
        "release cannot draw text with it.\n");
    g_unsetenv("FLUTTER_LINUX_RENDERER");
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
