// A small window to drag a file out of: what a file manager is to the app
// when a file is dragged from it and dropped on the planner. Used by
// tools/smoke-run.sh to check that drop for real, across two programs.
//
//   gcc $(pkg-config --cflags gtk+-3.0) tools/drag-source.c -o drag-source \
//       $(pkg-config --libs gtk+-3.0)
//   drag-source /path/to/file.ics
//
// Pressing anywhere in the window and moving away starts dragging the file.
#include <gtk/gtk.h>

static gchar* uri = NULL;

static void on_data_get(GtkWidget* widget, GdkDragContext* context,
                        GtkSelectionData* data, guint info, guint time,
                        gpointer user_data) {
  gchar* uris[] = {uri, NULL};
  gtk_selection_data_set_uris(data, uris);
}

int main(int argc, char** argv) {
  // The compositor knows the window by this name.
  g_set_prgname("fweek-drag-source");
  gtk_init(&argc, &argv);
  if (argc < 2) {
    g_printerr("usage: drag-source FILE\n");
    return 2;
  }
  g_autofree gchar* path = g_canonicalize_filename(argv[1], NULL);
  uri = g_filename_to_uri(path, NULL, NULL);

  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(window), 200, 120);
  GtkWidget* box = gtk_event_box_new();
  gtk_container_add(GTK_CONTAINER(window), box);
  gtk_container_add(GTK_CONTAINER(box), gtk_label_new("drag me"));
  gtk_drag_source_set(box, GDK_BUTTON1_MASK, NULL, 0, GDK_ACTION_COPY);
  gtk_drag_source_add_uri_targets(box);
  g_signal_connect(box, "drag-data-get", G_CALLBACK(on_data_get), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_show_all(window);
  gtk_main();
  return 0;
}
