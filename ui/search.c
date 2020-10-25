#include <glib/gi18n.h>
#include <gtk/gtk.h>

GtkWidget * activate (GtkApplication* app){

    GdkScreen *screen;
    GtkWidget *window;
    GtkWidget *hbox;
    GtkWidget *regex_button;
    GtkWidget *case_button;
    GtkWidget *whole_button;
    GtkWidget *continue_button;
    GtkWidget *selection_button;
    GtkWidget *highlight_button;
    GtkWidget *combo;
    GtkWidget *entry;
    GtkWidget *find_button;
    GtkWidget *find_prev_button;
    GtkWidget *find_all_button;
    GtkCssProvider *css;
    gint screenwidth;
    gint screenheight;
    gint windowwidth;
    gint windowheight;
    gint windowx;
    gint windowy;

    window = gtk_application_window_new(app);
    screen = gtk_window_get_screen(GTK_WINDOW(window));
    screenwidth = gdk_screen_get_width(screen);
    screenheight = gdk_screen_get_height(screen);
    windowwidth = 0.8*screenwidth;
    windowheight = 30;
    windowx = (0.2*screenwidth)-15;
    windowy = screenheight-100;
    
    gtk_widget_set_name(window, "window");
    gtk_window_set_default_size(GTK_WINDOW(window), windowwidth, windowheight);
    gtk_window_move(GTK_WINDOW(window), windowx, windowy);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_keep_above(GTK_WINDOW(window), TRUE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(window), TRUE);
    gtk_window_set_skip_pager_hint(GTK_WINDOW(window), TRUE);

    css = gtk_css_provider_new();
    gtk_css_provider_load_from_path(css, "search.css", NULL);
    gtk_style_context_add_provider_for_screen(screen,
                                              GTK_STYLE_PROVIDER(css),
                                              GTK_STYLE_PROVIDER_PRIORITY_USER);

    hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_container_add(GTK_CONTAINER(window), hbox);

    regex_button = gtk_button_new_with_label(".*");
    gtk_widget_set_size_request(regex_button, 0.01667*windowwidth, 20);
    gtk_widget_set_margin_start(regex_button, 5);
    gtk_widget_set_name(regex_button, "regex_button");
    gtk_box_pack_start(GTK_BOX(hbox), regex_button, FALSE, FALSE, 0);

    case_button = gtk_button_new_with_label("Aa");
    gtk_widget_set_size_request(case_button, 0.01667*windowwidth, 20);
    gtk_widget_set_name(case_button, "case_button");
    gtk_box_pack_start(GTK_BOX(hbox), case_button, FALSE, FALSE, 0);

    whole_button = gtk_button_new_with_label("\"\"");
    gtk_widget_set_size_request(whole_button, 0.01667*windowwidth, 20);
    gtk_widget_set_name(whole_button, "whole_button");
    gtk_box_pack_start(GTK_BOX(hbox), whole_button, FALSE, FALSE, 0);

    continue_button = gtk_button_new_with_label("\uf0e2");
    gtk_widget_set_size_request(continue_button, 0.01667*windowwidth, 20);
    gtk_widget_set_margin_start(continue_button, 5);
    gtk_widget_set_name(continue_button, "continue_button");
    gtk_box_pack_start(GTK_BOX(hbox), continue_button, FALSE, FALSE, 0);

    selection_button = gtk_button_new_with_label("\uf246");
    gtk_widget_set_size_request(selection_button, 0.01667*windowwidth, 20);
    gtk_widget_set_name(selection_button, "selection_button");
    gtk_box_pack_start(GTK_BOX(hbox), selection_button, FALSE, FALSE, 0);

    highlight_button = gtk_button_new_with_label("\uf096");
    gtk_widget_set_size_request(highlight_button, 0.01667*windowwidth, 20);
    gtk_widget_set_margin_start(highlight_button, 5);
    gtk_widget_set_name(highlight_button, "highlight_button");
    gtk_box_pack_start(GTK_BOX(hbox), highlight_button, FALSE, FALSE, 0);

    combo = gtk_combo_box_text_new_with_entry();
    gtk_widget_set_size_request(combo, 0.7*windowwidth-(8*5), 20);
    gtk_widget_set_margin_start(combo, 5);
    gtk_widget_set_name(combo, "combo");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), "One");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), "Two");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), "Three");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), "Four");
    gtk_box_pack_start(GTK_BOX(hbox), combo, FALSE, FALSE, 0);

    entry = gtk_bin_get_child(GTK_BIN(combo));
    gtk_widget_set_name(entry, "entry");

    find_button = gtk_button_new_with_label("Find");
    gtk_widget_set_size_request(find_button, 0.0667*windowwidth, 20);
    gtk_widget_set_margin_start(find_button, 5);
    gtk_widget_set_name(find_button, "find_button");
    gtk_box_pack_start(GTK_BOX(hbox), find_button, FALSE, FALSE, 0);

    find_prev_button = gtk_button_new_with_label("Find Prev");
    gtk_widget_set_size_request(find_prev_button, 0.0667*windowwidth, 20);
    gtk_widget_set_margin_start(find_prev_button, 5);
    gtk_widget_set_name(find_prev_button, "find_prev_button");
    gtk_box_pack_start(GTK_BOX(hbox), find_prev_button, FALSE, FALSE, 0);

    find_all_button = gtk_button_new_with_label("Find All");
    gtk_widget_set_size_request(find_all_button, 0.0667*windowwidth, 20);
    gtk_widget_set_margin_start(find_all_button, 5);
    gtk_widget_set_margin_end(find_all_button, 5);
    gtk_widget_set_name(find_all_button, "find_all_button");
    gtk_box_pack_start(GTK_BOX(hbox), find_all_button, FALSE, FALSE, 0);

    gtk_widget_show_all(window);
    gtk_entry_grab_focus_without_selecting(GTK_ENTRY(entry));
}

int main (int argc, char **argv){

    GtkApplication *app;
    int status;

    app = gtk_application_new("org.gtk.example", G_APPLICATION_FLAGS_NONE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);

    return status;
}
