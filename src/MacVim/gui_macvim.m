/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */
/*
 * gui_macvim.m
 *
 * Hooks for the Vim gui code.  Mainly passes control on to MMBackend.
 */

#import "MMBackend.h"
#import "MacVim.h"
#import "vim.h"
#import <Foundation/Foundation.h>


static int use_graphical_sign = 0;

static BOOL is_macos_high_sierra_or_later = NO;

// Max number of files to add to MRU in one go (this matches the maximum that
// Cocoa displays in the MRU -- if this changes in Cocoa then update this
// number as well).
static int MMMaxMRU = 10;
// Enabled when files passed on command line should not be added to MRU.
static BOOL MMNoMRU = NO;

static NSString *MMDefaultFontName = @"Menlo-Regular";
static int MMDefaultFontSize       = 11;
static char *MMDefaultFontSizeStr  = "h11";
static int MMMinFontSize           = 6;
static int MMMaxFontSize           = 100;

// This is duplicated in MMVimController. Could consolidate in the future.
static NSString *(system_font_weights[]) = { @"UltraLight", @"Thin", @"Light", @"Regular", @"Medium", @"Semibold", @"Bold", @"Heavy", @"Black" };

static BOOL MMShareFindPboard      = YES;

static GuiFont gui_macvim_font_with_name(char_u *name);
static int specialKeyToNSKey(int key);
static int vimModMaskToEventModifierFlags(int mods);

NSArray *descriptor_for_menu(vimmenu_T *menu);
vimmenu_T *menu_for_descriptor(NSArray *desc);



// -- Initialization --------------------------------------------------------

    void
macvim_early_init(void)
{
    NSBundle *bundle = [NSBundle mainBundle];
    if (bundle) {
        // Set environment variables $VIM and $VIMRUNTIME
        NSString *path = [[bundle resourcePath]
                                        stringByAppendingPathComponent:@"vim"];

        char_u *p = mch_getenv((char_u *)"VIM");
        if (p == NULL || *p == NUL) {
            vim_setenv((char_u*)"VIM", (char_u*)[path UTF8String]);
        }

        p = mch_getenv((char_u *)"VIMRUNTIME");
        if (p == NULL || *p == NUL) {
            path = [path stringByAppendingPathComponent:@"runtime"];
            vim_setenv((char_u*)"VIMRUNTIME", (char_u*)[path UTF8String]);
        }

        NSString *lang = [[[NSBundle mainBundle]
            preferredLocalizations] objectAtIndex:0];
        if ([lang isEqualToString:@"Japanese"])
            vim_setenv((char_u*)"LANG", (char_u*)"ja_JP.UTF-8");

        if (mch_isdir((char_u*)"/opt/local/share/terminfo") == FALSE)
            vim_setenv((char_u*)"TERMINFO", (char_u*)"/usr/share/terminfo");
    }

#if 0   // NOTE: setlocale(LC_ALL, "") seems to work after a restart so this is
        // not necessary.  The locale used depends on what "Region" is set
        // inside the "Formats" tab of the "International" System Preferences
        // pane.
    // Try to ensure that the locale is set to match that used by NSBundle to
    // load localized resources.  If there is a mismatch e.g. between the
    // MacVim menu and other menus, then this code needs to change (nb. the
    // MacVim menu is set up inside a nib file so the locale used for it is
    // chosen by NSBundle and the other menus are set up by Vim so their locale
    // matches whatever we set here).
    NSLocale *loc = [NSLocale currentLocale];
    if (loc) {
        NSString *s = [NSString stringWithFormat:@"%@_%@.UTF-8",
                                    [loc objectForKey:NSLocaleLanguageCode],
                                    [loc objectForKey:NSLocaleCountryCode]];
        setlocale(LC_ALL, [s UTF8String]);
        fprintf(stderr, "locale=%s\n", [s UTF8String]);
        fflush(stderr);
    }
#endif
}


/*
 * Parse the GUI related command-line arguments.  Any arguments used are
 * deleted from argv, and *argc is decremented accordingly.  This is called
 * when vim is started, whether or not the GUI has been started.
 * NOTE: This function will be called twice if the Vim process forks.
 */
    void
gui_mch_prepare(int *argc, char **argv)
{
    // NOTE! Vim expects this method to remove args that it handles from the
    // arg list but if the process then forks then these arguments will not
    // reach the child process due to the way forking is handled on Mac OS X.
    //
    // Thus, only delete arguments that imply that no forking is done.
    //
    // If you add an argument that does not imply no forking, then do not
    // delete it from the arg list.  Such arguments must be ignored in main.c
    // command_line_scan() or Vim will issue an error on startup when that
    // argument is used.

    int i = 0;
    while (i < *argc) {
        BOOL delarg = NO;
        if (strncmp(argv[i], "--mmwaitforack", 14) == 0) {
            // Implies -f (only called from front end)
            [[MMBackend sharedInstance] setWaitForAck:YES];
            delarg = YES;
        }
#ifdef FEAT_NETBEANS_INTG
        else if (strncmp(argv[i], "-nb", 3) == 0) {
            // TODO: Can this be used without -f?  If so, should not del arg.
            netbeansArg = argv[i];
            delarg = YES;
        }
#endif
        else if (strncmp(argv[i], "--nomru", 7) == 0) {
            // Can be used without -f, do not delete from arg list!
            MMNoMRU = YES;
        }

        if (delarg) {
            // NOTE: See comment above about when to delete arguments!
            --*argc;
            if (*argc > i)
                mch_memmove(&argv[i], &argv[i+1], (*argc-i) * sizeof(char*));
        } else
            ++i;
    }
}


/* Called directly after forking (even if we didn't fork). */
    void
gui_macvim_after_fork_init(void)
{
    ASLInit();
    ASLogDebug(@"");

    // Restore autosaved rows & columns
    CFIndex rows, cols;
    Boolean rowsValid, colsValid;
    rows = CFPreferencesGetAppIntegerValue((CFStringRef)MMAutosaveRowsKey,
                                        kCFPreferencesCurrentApplication,
                                        &rowsValid);
    cols = CFPreferencesGetAppIntegerValue((CFStringRef)MMAutosaveColumnsKey,
                                        kCFPreferencesCurrentApplication,
                                        &colsValid);
    if (rowsValid && colsValid
            && (rows > 4 && rows < 1000 && cols > 29 && cols < 4000)) {
        gui.num_rows = rows;
        gui.num_cols = cols;
    } else {
        // Use the defaults (typically 80x24), if there are no autosaved rows &
        // columns.
        gui.num_rows = Rows;
        gui.num_cols = Columns;
    }

    // Check which code path to take for string drawing.
    CFIndex val;
    Boolean keyValid;
    val = CFPreferencesGetAppIntegerValue((CFStringRef)MMRendererKey,
                                            kCFPreferencesCurrentApplication,
                                            &keyValid);
    if (!keyValid) {
        // If MMRendererKey is not valid in the defaults, it means MacVim uses
        // the Core Text Renderer.
        keyValid = YES;
        val = MMRendererCoreText;
    }
    if (val != MMRendererDefault && val != MMRendererCoreText) {
        // Migrate from the old value to the Core Text Renderer.
        val = MMRendererCoreText;
        CFPreferencesSetAppValue((CFStringRef)MMRendererKey,
                                (CFPropertyListRef)[NSNumber numberWithInt:val],
                                kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }
    if (keyValid) {
        ASLogInfo(@"Use renderer=%ld", val);

        // For now only the Core Text renderer knows how to render graphical
        // signs.
        use_graphical_sign = (val == MMRendererCoreText);
    }

    // Check to use the Find Pasteboard.
    MMShareFindPboard = CFPreferencesGetAppBooleanValue((CFStringRef)MMShareFindPboardKey,
                                                        kCFPreferencesCurrentApplication,
                                                        &keyValid);
    if (!keyValid) {
        // Share text via the Find Pasteboard by default.
        MMShareFindPboard = YES;
    }
}


/*
 * Check if the GUI can be started.  Called before gvimrc is sourced.
 * Return OK or FAIL.
 */
    int
gui_mch_init_check(void)
{
    return OK;
}


/*
 * Initialise the GUI.  Create all the windows, set up all the call-backs etc.
 * Returns OK for success, FAIL when the GUI can't be started.
 */
    int
gui_mch_init(void)
{
    ASLogDebug(@"");

    if (![[MMBackend sharedInstance] checkin]) {
        // TODO: Kill the process if there is no terminal to fall back on,
        // otherwise the process will run outputting to the console.
        return FAIL;
    }

    // Force 'termencoding' to utf-8 (changes to 'tenc' are disallowed in
    // 'option.c', so that ':set termencoding=...' is impossible).
    set_option_value((char_u *)"termencoding", 0L, (char_u *)"utf-8", 0);

    // Set values so that pixels and characters are in one-to-one
    // correspondence (assuming all characters have the same dimensions).
    gui.scrollbar_width = gui.scrollbar_height = 0;

    // For simplicity we just set char width/height to 1 as the GUI is
    // decoupled from Vim anyway so Vim doesn't need to know the accurate
    // pixel sizes.
    gui.char_height = 1;
    gui.char_width = 1;
    gui.char_ascent = 0;

    gui_mch_def_colors();

    [[MMBackend sharedInstance]
        setDefaultColorsBackground:gui.back_pixel foreground:gui.norm_pixel];
    [[MMBackend sharedInstance] setBackgroundColor:gui.back_pixel];
    [[MMBackend sharedInstance] setForegroundColor:gui.norm_pixel];

    // NOTE: If this call is left out the cursor is opaque.
    highlight_gui_started();

    // Ensure 'linespace' option is passed along to MacVim in case it was set
    // in [g]vimrc.
    gui_mch_adjust_charheight();
    gui_mch_adjust_charwidth();

    if (!MMNoMRU && GARGCOUNT > 0) {
        // Add files passed on command line to MRU.
        NSMutableArray *filenames = [NSMutableArray array];
        int i, count = GARGCOUNT > MMMaxMRU ? MMMaxMRU : GARGCOUNT;
        for (i = 0; i < count; ++i) {
            char_u *fname = GARGLIST[i].ae_fname;
            if (!fname) continue;

            // Expand to a full file name (including the full path).
            char_u *ffname = fix_fname(fname);
            if (!ffname) continue;

            [filenames addObject:[NSString stringWithVimString:ffname]];
            vim_free(ffname);
        }

        [[MMBackend sharedInstance] addToMRU:filenames];
    }

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_10
    if ([[NSProcessInfo processInfo]
              respondsToSelector:@selector(isOperatingSystemAtLeastVersion:)])
    {
        NSOperatingSystemVersion version = {10, 13, 0};

        is_macos_high_sierra_or_later = [[NSProcessInfo processInfo]
                                     isOperatingSystemAtLeastVersion:version];
    }
#endif

    return OK;
}



    void
gui_mch_exit(int rc)
{
    ASLogDebug(@"rc=%d", rc);

    [[MMBackend sharedInstance] exit];
}


/*
 * Open the GUI window which was created by a call to gui_mch_init().
 */
    int
gui_mch_open(void)
{
    return [[MMBackend sharedInstance] openGUIWindow];
}


// -- Updating --------------------------------------------------------------


/*
 * Catch up with any queued X events.  This may put keyboard input into the
 * input buffer, call resize call-backs, trigger timers etc.  If there is
 * nothing in the X event queue (& no timers pending), then we return
 * immediately.
 */
    void
gui_mch_update(void)
{
    // This function is called extremely often.  It is tempting to do nothing
    // here to avoid reduced frame-rates but then it would not be possible to
    // interrupt Vim by presssing Ctrl-C during lengthy operations (e.g. after
    // entering "10gs" it would not be possible to bring Vim out of the 10 s
    // sleep prematurely).  Furthermore, Vim sometimes goes into a loop waiting
    // for keyboard input (e.g. during a "more prompt") where not checking for
    // input could cause Vim to lock up indefinitely.
    //
    // As a compromise we check for new input only every now and then. Note
    // that Cmd-. sends SIGINT so it has higher success rate at interrupting
    // Vim than Ctrl-C.
    static CFAbsoluteTime lastTime = 0;

    CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
    if (nowTime - lastTime > 1.0 / 30) {
        gui_macvim_update();
        lastTime = nowTime;
    }
}


    void
gui_macvim_update(void)
{
    [[MMBackend sharedInstance] update];
}


/* Flush any output to the screen */
    void
gui_mch_flush(void)
{
    // This function is called way too often to be useful as a hint for
    // flushing.  If we were to flush every time it was called the screen would
    // flicker.
}


    void
gui_macvim_flush(void)
{
    // This function counts how many times it is called and only flushes the
    // draw queue if called sufficiently often.  The first few times it is
    // called it will flush often, but the more it is called the less likely is
    // it that anything will be flushed.  (The counter resets itself if the
    // function isn't called for a second.)
    //
    // NOTE: Should only be used in loops where it is impossible to know how
    // often Vim needs to flush.  It was written to handle output from external
    // commands (see mch_call_shell() in os_unix.c).

    static CFAbsoluteTime lastTime = 0;
    static int delay = 1;
    static int counter = 0;
    static int scrolls = 0;

    CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime delta = nowTime - lastTime;
    if (delta > 1.0)
        delay = 1;

    // We assume that each call corresponds roughly to one line of output.
    // When one page has scrolled by we increase the delay before the next
    // flush.
    if (++scrolls > gui.num_rows) {
        delay <<= 1;
        if (delay > 2048)
            delay = 2048;
        scrolls = 0;
    }

    if (++counter > delay) {
        gui_macvim_force_flush();
        counter = 0;
    }

    lastTime = nowTime;
}


/* Force flush output to MacVim.  Do not call this method unless absolutely
 * necessary. */
    void
gui_macvim_force_flush(void)
{
    [[MMBackend sharedInstance] flushQueue:YES];
}


/*
 * GUI input routine called by gui_wait_for_chars().  Waits for a character
 * from the keyboard.
 *  wtime == -1	    Wait forever.
 *  wtime == 0	    This should never happen.
 *  wtime > 0	    Wait wtime milliseconds for a character.
 * Returns OK if a character was found to be available within the given time,
 * or FAIL otherwise.
 */
    int
gui_mch_wait_for_chars(int wtime)
{
    // NOTE! In all likelihood Vim will take a nap when waitForInput: is
    // called, so force a flush of the command queue here.
    [[MMBackend sharedInstance] flushQueue:YES];

#ifdef MESSAGE_QUEUE
# ifdef FEAT_TIMERS
    did_add_timer = FALSE;
# endif

    parse_queued_messages();

# ifdef FEAT_TIMERS
    if (did_add_timer)
        wtime = 0;
# endif
#endif

    return [[MMBackend sharedInstance] waitForInput:wtime];
}


// -- Drawing ---------------------------------------------------------------


/*
 * Clear the whole text window.
 */
    void
gui_mch_clear_all(void)
{
    [[MMBackend sharedInstance] clearAll];
}


/*
 * Clear a rectangular region of the screen from text pos (row1, col1) to
 * (row2, col2) inclusive.
 */
    void
gui_mch_clear_block(int row1, int col1, int row2, int col2)
{
    [[MMBackend sharedInstance] clearBlockFromRow:row1 column:col1
                                                    toRow:row2 column:col2];
}


/*
 * Delete the given number of lines from the given row, scrolling up any
 * text further down within the scroll region.
 */
    void
gui_mch_delete_lines(int row, int num_lines)
{
    [[MMBackend sharedInstance] deleteLinesFromRow:row count:num_lines
            scrollBottom:gui.scroll_region_bot
                    left:gui.scroll_region_left
                   right:gui.scroll_region_right];
}


    int
gui_macvim_draw_string(int row, int col, char_u *s, int len, int flags)
{
    MMBackend *backend = [MMBackend sharedInstance];
    int c, cw, cl, ccl;
    int start = 0;
    int endcol = col;
    int startcol = col;
    BOOL wide = NO;
    char_u *conv_str = NULL;

    if (output_conv.vc_type != CONV_NONE) {
        conv_str = string_convert(&output_conv, s, &len);
        if (conv_str)
            s = conv_str;
    }

    // Loop over each character and output text when it changes from normal to
    // wide and vice versa.
    for (int i = 0; i < len; i += cl) {
        c = utf_ptr2char(s + i);
        cw = utf_char2cells(c);
        cl = utf_ptr2len(s + i);
        ccl = utfc_ptr2len(s + i);
        if (cl == 0)
            len = i;    // len must be wrong (shouldn't happen)

        if (i > start && (cl < ccl || (cw > 1 && !wide) || (cw <= 1 && wide))) {
            // Changed from normal to wide or vice versa.
            [backend drawString:(s+start) length:i-start
                            row:row column:startcol
                          cells:endcol-startcol
                          flags:flags|(wide ? DRAW_WIDE : 0)];

            start = i;
            startcol = endcol;
        }

        wide = cw > 1;
        endcol += cw;

        if (cl < ccl) {
            // Changed from normal to wide or vice versa.
            [backend drawString:(s+start) length:ccl
                            row:row column:startcol
                          cells:endcol-startcol
                          flags:flags|DRAW_COMP|(wide ? DRAW_WIDE : 0)];

            start = i + ccl;
            startcol = endcol;
            cl = ccl;
        }
    }

    if (len > start) {
        // Output remaining characters.
        [backend drawString:(s+start) length:len-start
			row:row column:startcol
		      cells:endcol-startcol
		      flags:flags|(wide ? DRAW_WIDE : 0)];
    }

    if (conv_str)
        vim_free(conv_str);

    return endcol - col;
}


/*
 * Insert the given number of lines before the given row, scrolling down any
 * following text within the scroll region.
 */
    void
gui_mch_insert_lines(int row, int num_lines)
{
    [[MMBackend sharedInstance] insertLinesFromRow:row count:num_lines
            scrollBottom:gui.scroll_region_bot
                    left:gui.scroll_region_left
                   right:gui.scroll_region_right];
}


/*
 * Set the current text foreground color.
 */
    void
gui_mch_set_fg_color(guicolor_T color)
{
    [[MMBackend sharedInstance] setForegroundColor:color];
}


/*
 * Set the current text background color.
 */
    void
gui_mch_set_bg_color(guicolor_T color)
{
    [[MMBackend sharedInstance] setBackgroundColor:color];
}


/*
 * Set the current text special color (used for underlines).
 */
    void
gui_mch_set_sp_color(guicolor_T color)
{
    [[MMBackend sharedInstance] setSpecialColor:color];
}


/*
 * Set default colors.
 */
    void
gui_mch_def_colors(void)
{
    MMBackend *backend = [MMBackend sharedInstance];

    // The default colors are taken from system values
    gui.def_norm_pixel = gui.norm_pixel = 
        [backend lookupColorWithKey:@"MacTextColor"];
    gui.def_back_pixel = gui.back_pixel = 
        [backend lookupColorWithKey:@"MacTextBackgroundColor"];
}


/*
 * Called when the foreground or background color has been changed.
 */
    void
gui_mch_new_colors(void)
{
    gui.def_back_pixel = gui.back_pixel;
    gui.def_norm_pixel = gui.norm_pixel;

    ASLogDebug(@"back=%ld norm=%ld", gui.def_back_pixel, gui.def_norm_pixel);

    [[MMBackend sharedInstance]
        setDefaultColorsBackground:gui.def_back_pixel
                        foreground:gui.def_norm_pixel];
}

/*
 * Called when any highlight has been changed in general
 */
    void
gui_mch_update_highlight(void)
{
    // If using a highlight group for fullscreen background color we need to
    // update the app when a new color scheme has been picked. This function
    // technically wouldn't be called if a user manually set the relevant
    // highlight group to another color but works in most use cases when they
    // just change the color scheme.
    if (fuoptions_flags & FUOPT_BGCOLOR_HLGROUP)
        gui_mch_fuopt_update();

    // Update the GUI with tab colors

    // Highlight attributes for TabLine, TabLineFill, TabLineSel
    const int attrs[3] = { HL_ATTR(HLF_TP), HL_ATTR(HLF_TPF), HL_ATTR(HLF_TPS) };

    int tablineColors[6] = { 0 };
    for (int i = 0; i < 3; i++) {
        guicolor_T bg = INVALCOLOR, fg = INVALCOLOR;
        BOOL reverse = NO;
        if (attrs[i] > HL_ALL) {
            attrentry_T *aep = syn_gui_attr2entry(attrs[i]);
            if (aep != NULL) {
                bg = aep->ae_u.gui.bg_color;
                fg = aep->ae_u.gui.fg_color;
                reverse = (aep->ae_attr & HL_INVERSE) != 0;
            }
        } else {
            reverse = (attrs[i] & HL_INVERSE) != 0;
        }

        if (bg == INVALCOLOR)
            bg = gui.def_back_pixel;
        if (fg == INVALCOLOR)
            fg = gui.def_norm_pixel;

        if (reverse) {
            guicolor_T temp = fg;
            fg = bg;
            bg = temp;
        }
        tablineColors[i*2] = (int)bg;
        tablineColors[i*2+1] = (int)fg;
    }
    // Cache the old colors just so we don't spam the IPC channel if the
    // colors didn't actually change.
    static int oldTablineColors[6] = { 0 };
    if (memcmp(oldTablineColors, tablineColors, sizeof(oldTablineColors)) != 0) {
        memcpy(oldTablineColors, tablineColors, sizeof(oldTablineColors));
        [[MMBackend sharedInstance] setTablineColors:tablineColors];
    }
}

/*
 * Invert a rectangle from row r, column c, for nr rows and nc columns.
 */
    void
gui_mch_invert_rectangle(int r, int c, int nr, int nc, int invert)
{
    [[MMBackend sharedInstance] drawInvertedRectAtRow:r column:c numRows:nr
            numColumns:nc invert:invert];
}



// -- Tabline ---------------------------------------------------------------


/*
 * Set the current tab to "nr".  First tab is 1.
 */
    void
gui_mch_set_curtab(int nr)
{
    [[MMBackend sharedInstance] selectTab:nr];
}


/*
 * Return TRUE when tabline is displayed.
 */
    int
gui_mch_showing_tabline(void)
{
    return [[MMBackend sharedInstance] tabBarVisible];
}

/*
 * Update the labels of the tabline.
 */
    void
gui_mch_update_tabline(void)
{
    [[MMBackend sharedInstance] updateTabBar];
}

/*
 * Show or hide the tabline.
 */
    void
gui_mch_show_tabline(int showit)
{
    [[MMBackend sharedInstance] showTabBar:showit];
}


// -- Menu ------------------------------------------------------------------


/*
 * A menu descriptor represents the "address" of a menu as an array of strings.
 * E.g. the menu "File->Close" has descriptor { "File", "Close" }.
 */
    NSArray *
descriptor_for_menu(vimmenu_T *menu)
{
    if (!menu) return nil;

    NSMutableArray *desc = [NSMutableArray array];
    while (menu) {
        NSString *name = [NSString stringWithVimString:menu->dname];
        [desc insertObject:name atIndex:0];
        menu = menu->parent;
    }

    return desc;
}

    vimmenu_T *
menu_for_descriptor(NSArray *desc)
{
    if (!(desc && [desc count] > 0)) return NULL;

    vimmenu_T *menu = root_menu;
    int i, count = [desc count];

    for (i = 0; i < count; ++i) {
        NSString *component = [desc objectAtIndex:i];
        while (menu) {
            NSString *name = [NSString stringWithVimString:menu->dname];
            if ([component isEqual:name]) {
                if (i+1 == count)
                    return menu;    // Matched all components, so return menu
                menu = menu->children;
                break;
            }
            menu = menu->next;
        }
    }

    return NULL;
}

/*
 * Add a submenu to the menu bar, toolbar, or a popup menu.
 */
    void
gui_mch_add_menu(vimmenu_T *menu, int idx)
{
    NSArray *desc = descriptor_for_menu(menu);
    [[MMBackend sharedInstance] queueMessage:AddMenuMsgID properties:
        [NSDictionary dictionaryWithObjectsAndKeys:
            desc, @"descriptor",
            [NSNumber numberWithInt:idx], @"index",
            nil]];
}


// Look up the icon file. If it's a full path, return that. Otherwise, look for
// it under a 'bitmaps' folder under runtimepath, using common file extensions.
// Taken from gui_gtk.c (slightly modified)
    static int
lookup_menu_iconfile(char_u *iconfile, char_u *dest)
{
    expand_env(iconfile, dest, MAXPATHL);

    if (mch_isFullName(dest))
	return vim_fexists(dest);

    // Just find the popular image formats that macOS supports.
    static const char   suffixes[][5] = {
       "png", "bmp", "ico", "icns", "jpeg", "jpg", "heic", "webp"};
    char_u		buf[MAXPATHL];
    unsigned int	i;

    for (i = 0; i < sizeof(suffixes)/sizeof(suffixes[0]); ++i)
        if (gui_find_bitmap(dest, buf, (char *)suffixes[i]) == OK) {
            STRCPY(dest, buf);
            return TRUE;
        }

    return FALSE;
}


/*
 * Add a menu item to a menu
 */
    void
gui_mch_add_menu_item(vimmenu_T *menu, int idx)
{
    char_u *tip = menu->strings[MENU_INDEX_TIP]
            ? menu->strings[MENU_INDEX_TIP] : menu->actext;
    NSArray *desc = descriptor_for_menu(menu);
    NSString *keyEquivalent = menu->mac_key
        ? [NSString stringWithFormat:@"%C",
                            (unsigned short)specialKeyToNSKey(menu->mac_key)]
        : [NSString string];
    int modifierMask = vimModMaskToEventModifierFlags(menu->mac_mods);
    NSString *icon = nil;

    vimmenu_T *rootMenu = menu;
    while (rootMenu->parent) {
        rootMenu = rootMenu->parent;
    }
    if (menu_is_toolbar(rootMenu->name)) {
        // Find out what file to load for the toolbar icon.
        char_u fname[MAXPATHL];

        // Try to use the file path from the icon=.. argument
        if (menu->iconfile && lookup_menu_iconfile(menu->iconfile, fname))
            icon = [NSString stringWithVimString:fname];

        // If not found and not builtin specified try using the menu name
        if (icon == nil && !menu->icon_builtin
                                    && lookup_menu_iconfile(menu->name, fname))
            icon = [NSString stringWithVimString:fname];

        // Still no icon found, try using a builtin icon.  (If this also fails,
        // then a warning icon will be displayed).
        if (icon == nil) {
            char_u* toolbar_item = lookup_toolbar_item(menu->iconidx);
            if (toolbar_item) {
                icon = [NSString stringWithVimString:toolbar_item];

                // All the default icons that MacVim ships with are templates
                // to make them work better in light/dark modes.
                icon = [icon stringByAppendingString:@":template"];
            }
        }

        // Last step is to simply pass the icon argument up the chain as there
        // are more complicated logic to determine what this is (e.g. SF Symbol
        // or raw image).
        if (icon == nil) {
            if (menu->iconfile && *menu->iconfile != '\0') {
                icon = [NSString stringWithVimString:menu->iconfile];
            }
        }
    } else {
        // For regular menus, we support icons as well, but only if it's
        // specified by the icon=... argument. This is a MacVim-extension.
        char_u fname[MAXPATHL];

        if (menu->iconfile && *menu->iconfile != '\0') {
            if (lookup_menu_iconfile(menu->iconfile, fname)) {
                icon = [NSString stringWithVimString:fname];
            } else {
                icon = [NSString stringWithVimString:menu->iconfile];
            }
        }
    }

    if (icon == nil) {
        // Need non-nil items for dictionaryWithObjectsAndKeys: below.
        icon = @"";
    }

    [[MMBackend sharedInstance] queueMessage:AddMenuItemMsgID properties:
        [NSDictionary dictionaryWithObjectsAndKeys:
            desc, @"descriptor",
            [NSNumber numberWithInt:idx], @"index",
            [NSString stringWithVimString:tip], @"tip",
            icon, @"icon",
            keyEquivalent, @"keyEquivalent",
            [NSNumber numberWithInt:modifierMask], @"modifierMask",
            [NSString stringWithVimString:menu->mac_action], @"action",
            [NSNumber numberWithBool:menu->mac_alternate], @"isAlternate",
            nil]];
}


/*
 * Destroy the machine specific menu widget.
 */
    void
gui_mch_destroy_menu(vimmenu_T *menu)
{
    NSArray *desc = descriptor_for_menu(menu);
    [[MMBackend sharedInstance] queueMessage:RemoveMenuItemMsgID properties:
        [NSDictionary dictionaryWithObject:desc forKey:@"descriptor"]];
}


/*
 * Make a menu either grey or not grey.
 */
    void
gui_mch_menu_grey(vimmenu_T *menu, int grey)
{
    // Only update menu if the 'grey' state has changed to avoid having to pass
    // lots of unnecessary data to MacVim.  (Skipping this test makes MacVim
    // pause noticably on mode changes.
    NSArray *desc = descriptor_for_menu(menu);
    if (menu->was_grey == grey)
        return;

    menu->was_grey = grey;

    [[MMBackend sharedInstance] queueMessage:EnableMenuItemMsgID properties:
        [NSDictionary dictionaryWithObjectsAndKeys:
            desc, @"descriptor",
            [NSNumber numberWithInt:!grey], @"enable",
            nil]];
}


/*
 * Make menu item hidden or not hidden
 */
    void
gui_mch_menu_hidden(vimmenu_T *menu, int hidden)
{
    // HACK! There is no (obvious) way to hide a menu item, so simply
    // enable/disable it instead.
    gui_mch_menu_grey(menu, hidden);
}


/*
 * This is called when user right clicks.
 */
    void
gui_mch_show_popupmenu(vimmenu_T *menu)
{
    NSArray *desc = descriptor_for_menu(menu);
    [[MMBackend sharedInstance] queueMessage:ShowPopupMenuMsgID properties:
        [NSDictionary dictionaryWithObject:desc forKey:@"descriptor"]];
}


/*
 * Update a menu's tooltip.
 */
    void
gui_mch_menu_set_tip(vimmenu_T *menu)
{
    char_u *tip = menu->strings[MENU_INDEX_TIP];
    NSArray *desc = descriptor_for_menu(menu);
    [[MMBackend sharedInstance] queueMessage:UpdateMenuItemTooltipMsgID properties:
        [NSDictionary dictionaryWithObjectsAndKeys:
            desc, @"descriptor",
            [NSString stringWithVimString:tip], @"tip",
            nil]];
}


/*
 * This is called when a :popup command is executed.
 */
    void
gui_make_popup(char_u *path_name, int mouse_pos)
{
    vimmenu_T *menu = gui_find_menu(path_name);
    if (!(menu && menu->children)) return;

    NSArray *desc = descriptor_for_menu(menu);
    NSDictionary *p = (mouse_pos || NULL == curwin)
        ? [NSDictionary dictionaryWithObject:desc forKey:@"descriptor"]
        : [NSDictionary dictionaryWithObjectsAndKeys:
            desc, @"descriptor",
            [NSNumber numberWithInt:curwin->w_wrow], @"row",
            [NSNumber numberWithInt:curwin->w_wcol], @"column",
            nil];

    [[MMBackend sharedInstance] queueMessage:ShowPopupMenuMsgID properties:p];
}


/*
 * This is called after setting all the menus to grey/hidden or not.
 */
    void
gui_mch_draw_menubar(void)
{
    // The (main) menu draws itself in Mac OS X.
}


    void
gui_mch_enable_menu(int flag UNUSED)
{
    // The (main) menu is always enabled in Mac OS X.
}


#if 0
    void
gui_mch_set_menu_pos(int x, int y, int w, int h)
{
    // The (main) menu cannot be moved in Mac OS X.
}
#endif


    void
gui_mch_show_toolbar(int showit)
{
    int flags = 0;
    if (toolbar_flags & TOOLBAR_TEXT) flags |= ToolbarLabelFlag;
    if (toolbar_flags & TOOLBAR_ICONS) flags |= ToolbarIconFlag;
    if (tbis_flags & (TBIS_MEDIUM|TBIS_LARGE)) flags |= ToolbarSizeRegularFlag;

    [[MMBackend sharedInstance] showToolbar:showit flags:flags];
}




// -- Fonts -----------------------------------------------------------------


/*
 * If a font is not going to be used, free its structure.
 */
    void
gui_mch_free_font(GuiFont font)
{
    if (font != NOFONT) {
        ASLogDebug(@"font=%p", font);
        [(id)font release];
    }
}


    GuiFont
gui_mch_retain_font(GuiFont font)
{
    return (GuiFont)[(id)font retain];
}


/*
 * Get a font structure for highlighting.
 */
    GuiFont
gui_mch_get_font(char_u *name, int giveErrorIfMissing)
{
    ASLogDebug(@"name='%s' giveErrorIfMissing=%d", name, giveErrorIfMissing);

    GuiFont font = gui_macvim_font_with_name(name);
    if (font != NOFONT)
        return font;

    if (giveErrorIfMissing)
        semsg(_(e_unknown_font_str), name);

    return NOFONT;
}


#if defined(FEAT_EVAL) || defined(PROTO)
/*
 * Return the name of font "font" in allocated memory.
 */
    char_u *
gui_mch_get_fontname(GuiFont font, char_u *name)
{
    return font ? [(NSString *)font vimStringSave]
                : (name ? vim_strsave(name) : NULL);
}
#endif


/*
 * Initialise vim to use the font with the given name.	Return FAIL if the font
 * could not be loaded, OK otherwise.
 */
    int
gui_mch_init_font(char_u *font_name, int fontset)
{
    ASLogDebug(@"font_name='%s' fontset=%d", font_name, fontset);

    if (font_name && STRCMP(font_name, "*") == 0) {
        // :set gfn=* shows the font panel.
        do_cmdline_cmd((char_u*)":macaction orderFrontFontPanel:");
        return FAIL;
    }

    GuiFont font = gui_macvim_font_with_name(font_name);
    if (font == NOFONT)
        return FAIL;

    gui_mch_free_font(gui.norm_font);
    gui.norm_font = font;

    // NOTE: MacVim keeps separate track of the normal and wide fonts.
    // Unless the user changes 'guifontwide' manually, they are based on
    // the same (normal) font.  Also note that each time the normal font is
    // set, the advancement may change so the wide font needs to be updated
    // as well (so that it is always twice the width of the normal font).
    [[MMBackend sharedInstance] setFont:font wide:NO];
    [[MMBackend sharedInstance] setFont:(NOFONT != gui.wide_font ? gui.wide_font
                                                                 : font)
                                   wide:YES];

    return OK;
}


/*
 * Set the current text font.
 */
    void
gui_mch_set_font(GuiFont font UNUSED)
{
    // Font selection is done inside MacVim...nothing here to do.
}


/*
 * Return GuiFont in allocated memory.  The caller must free it using
 * gui_mch_free_font().
 */
    GuiFont
gui_macvim_font_with_name(char_u *name)
{
    if (!name)
        return (GuiFont)[[NSString alloc] initWithFormat:@"%@:h%d",
                                        MMDefaultFontName, MMDefaultFontSize];

    NSString *fontName = [NSString stringWithVimString:name];
    int size = MMDefaultFontSize;
    BOOL parseFailed = NO;

    NSArray *components = [fontName componentsSeparatedByString:@":"];
    if ([components count] == 2) {
        NSString *sizeString = [components lastObject];
        if ([sizeString length] > 0
                && [sizeString characterAtIndex:0] == 'h') {
            sizeString = [sizeString substringFromIndex:1];
            if ([sizeString length] > 0) {
                size = (int)round([sizeString floatValue]);
                fontName = [components objectAtIndex:0];
            }
        } else {
            parseFailed = YES;
        }
    } else if ([components count] > 2) {
        parseFailed = YES;
    }

    if (!parseFailed) {
        // Replace underscores with spaces.
        fontName = [[fontName componentsSeparatedByString:@"_"]
                                 componentsJoinedByString:@" "];
    }

    const BOOL isSystemFont = [fontName hasPrefix:MMSystemFontAlias];
    if (isSystemFont) {
        if (fontName.length > MMSystemFontAlias.length) {
            BOOL invalidWeight = YES;
            const NSRange cmpRange = NSMakeRange(MMSystemFontAlias.length, fontName.length - MMSystemFontAlias.length);
            for (size_t i = 0; i < ARRAY_LENGTH(system_font_weights); i++) {
                if ([fontName compare:system_font_weights[i] options:NSCaseInsensitiveSearch range:cmpRange] == NSOrderedSame) {
                    invalidWeight = NO;
                    break;
                }
            }
            if (invalidWeight)
                return NOFONT;
        }
    }

    if (!parseFailed && [fontName length] > 0) {
        if (size < MMMinFontSize) size = MMMinFontSize;
        if (size > MMMaxFontSize) size = MMMaxFontSize;

        // If the default font is requested we don't need to check if NSFont
        // can load it.  Otherwise we ask NSFont if it can load it.
        if ([fontName isEqualToString:MMDefaultFontName]
                || isSystemFont
                || [NSFont fontWithName:fontName size:size])
            return [[NSString alloc] initWithFormat:@"%@:h%d", fontName, size];
    }

    return NOFONT;
}

/**
 * Cmdline expansion for setting 'guifont' / 'guifontwide'. Will enumerate
 * through all fonts for completion. When setting 'guifont' it will only show
 * monospace fonts as it's unlikely other fonts would be useful.
 */
    void
gui_mch_expand_font(optexpand_T *args, void *param, int (*add_match)(char_u *val))
{
    expand_T *xp = args->oe_xp;
    int wide = *(int *)param;

    if (args->oe_include_orig_val && *args->oe_opt_value == NUL && !wide)
    {
	// If guifont is empty, and we want to fill in the orig value, suggest
	// the default so the user can modify it.
        NSString *defaultFontStr = [NSString stringWithFormat:@"%@:h%d",
                 MMDefaultFontName, MMDefaultFontSize];
	if (add_match((char_u *)[defaultFontStr UTF8String]) != OK)
	    return;
    }

    if (xp->xp_pattern > args->oe_set_arg && *(xp->xp_pattern-1) == ':')
    {
        // Fill in the existing font size to help switching only font family
        char_u *colon = vim_strchr(p_guifont, ':');
        if (colon != NULL)
            add_match(colon + 1);
        else
            add_match((char_u*)MMDefaultFontSizeStr);
        return;
    }

    if (!wide) {
        // Add system-native monospace font alias to completion.
        char buf[40];
        [MMSystemFontAlias getCString:buf maxLength:ARRAY_LENGTH(buf) encoding:NSASCIIStringEncoding];
        if (add_match((char_u*)buf) != OK)
            return;
        const size_t fontAliasLen = STRLEN(buf);
        if (STRNCMP(xp->xp_pattern, buf, fontAliasLen) == 0) {
            // We additionally complete with font weights like "bold". We only
            // do so if starting with "-monospace-" already to avoid spamming
            // the user with too many variations on this.
            for (size_t i = 0; i < ARRAY_LENGTH(system_font_weights); i++) {
                [system_font_weights[i] getCString:buf+fontAliasLen
                                         maxLength:ARRAY_LENGTH(buf)-fontAliasLen
                                          encoding:NSASCIIStringEncoding];
                if (add_match((char_u*)buf) != OK)
                    return;
            }
        }
    }

    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    NSArray<NSString *> *availableFonts;
    if (wide)
        availableFonts = [fontManager availableFonts];
    else
        availableFonts = [fontManager availableFontNamesWithTraits:NSFixedPitchFontMask];
    for (NSString *font in availableFonts) {
        if (add_match((char_u*)[font UTF8String]) != OK)
            return;
    }
}

// -- Scrollbars ------------------------------------------------------------

// NOTE: Even though scrollbar identifiers are 'long' we tacitly assume that
// they only use 32 bits (in particular when compiling for 64 bit).  This is
// justified since identifiers are generated from a 32 bit counter in
// gui_create_scrollbar().  However if that code changes we may be in trouble
// (if ever that many scrollbars are allocated...).  The reason behind this is
// that we pass scrollbar identifers over process boundaries so the width of
// the variable needs to be fixed (and why fix at 64 bit when only 32 are
// really used?).

    void
gui_mch_create_scrollbar(
	scrollbar_T *sb,
	int orient UNUSED)	/* SBAR_VERT or SBAR_HORIZ */
{
    [[MMBackend sharedInstance] 
            createScrollbarWithIdentifier:(int32_t)sb->ident type:sb->type];
}


    void
gui_mch_destroy_scrollbar(scrollbar_T *sb)
{
    [[MMBackend sharedInstance] 
            destroyScrollbarWithIdentifier:(int32_t)sb->ident];
}


    void
gui_mch_enable_scrollbar(
	scrollbar_T	*sb,
	int		flag)
{
    [[MMBackend sharedInstance] 
            showScrollbarWithIdentifier:(int32_t)sb->ident state:flag];
}


    void
gui_mch_set_scrollbar_pos(
	scrollbar_T *sb,
	int x,
	int y,
	int w,
	int h)
{
    int pos = y;
    int len = h;
    if (SBAR_BOTTOM == sb->type) {
        pos = x;
        len = w; 
    }

    [[MMBackend sharedInstance] 
            setScrollbarPosition:pos length:len identifier:(int32_t)sb->ident];
}


    int
gui_mch_get_scrollbar_xpadding(void)
{
    // TODO: Calculate the padding for adjust scrollbar position when the
    // Window is maximized.
    return 0;
}


    int
gui_mch_get_scrollbar_ypadding(void)
{
    // TODO: Calculate the padding for adjust scrollbar position when the
    // Window is maximized.
    return 0;
}


    void
gui_mch_set_scrollbar_thumb(
	scrollbar_T *sb,
	long val,
	long size,
	long max)
{
    [[MMBackend sharedInstance] 
            setScrollbarThumbValue:val
                              size:size
                               max:max
                        identifier:(int32_t)sb->ident];
}


// -- Cursor ----------------------------------------------------------------


/*
 * Draw a cursor without focus.
 */
    void
gui_mch_draw_hollow_cursor(guicolor_T color)
{
    return [[MMBackend sharedInstance]
        drawCursorAtRow:gui.row column:gui.col shape:MMInsertionPointHollow
               fraction:100 color:color];
}


/*
 * Draw part of a cursor, only w pixels wide, and h pixels high.
 */
    void
gui_mch_draw_part_cursor(int w UNUSED, int h UNUSED, guicolor_T color)
{
    // HACK!  'w' and 'h' are always 1 since we do not tell Vim about the exact
    // font dimensions.  Thus these parameters are useless.  Instead we look at
    // the shape_table to determine the shape and size of the cursor (just like
    // gui_update_cursor() does).

    int idx = get_shape_idx(FALSE);
    int shape = MMInsertionPointBlock;
    switch (shape_table[idx].shape) {
        case SHAPE_HOR:
            shape = MMInsertionPointHorizontal;
            break;
        case SHAPE_VER:
            shape =
#ifdef FEAT_RIGHTLEFT
                    // If 'rl' is set the insert mode cursor may be drawn on
                    // the right-hand side of a text cell.
                    CURSOR_BAR_RIGHT ? MMInsertionPointVerticalRight :
#endif
                    MMInsertionPointVertical;
            break;
    }

    return [[MMBackend sharedInstance]
        drawCursorAtRow:gui.row column:gui.col shape:shape
               fraction:shape_table[idx].percentage color:color];
}


    int
gui_mch_is_blinking(void)
{
    return FALSE;
}


    int
gui_mch_is_blink_off(void)
{
    return FALSE;
}


/*
 * Cursor blink functions.
 *
 * This is a simple state machine:
 * BLINK_NONE	not blinking at all
 * BLINK_OFF	blinking, cursor is not shown
 * BLINK_ON blinking, cursor is shown
 */
    void
gui_mch_set_blinking(long wait, long on, long off)
{
    [[MMBackend sharedInstance] setBlinkWait:wait on:on off:off];
}


/*
 * Start the cursor blinking.  If it was already blinking, this restarts the
 * waiting time and shows the cursor.
 */
    void
gui_mch_start_blink(void)
{
    [[MMBackend sharedInstance] startBlink];
}


/*
 * Stop the cursor blinking.  Show the cursor if it wasn't shown.
 */
    void
gui_mch_stop_blink(int may_call_gui_update_cursor)
{
    [[MMBackend sharedInstance] stopBlink:may_call_gui_update_cursor];
}


// -- Mouse -----------------------------------------------------------------


/*
 * Get current mouse coordinates in text window.
 */
    void
gui_mch_getmouse(int *x UNUSED, int *y UNUSED)
{
    ASLogInfo(@"Not implemented!");
}


    void
gui_mch_setmouse(int x UNUSED, int y UNUSED)
{
    ASLogInfo(@"Not implemented!");
}

    void
gui_mch_mousehide(int hide UNUSED)
{
    // We don't implement this. `insertVimStateMessage` already sends this to
    // MacVim, and we handle this in the parent process using NSCursor's
    // `setHiddenUntilMouseMoves` instead of letting Vim have manual control
    // over this.
}


    void
mch_set_mouse_shape(int shape)
{
    [[MMBackend sharedInstance] setMouseShape:shape];
}




// -- Input Method ----------------------------------------------------------

#if defined(FEAT_EVAL)
# ifdef FEAT_GUI
#  define USE_IMACTIVATEFUNC (!gui.in_use && *p_imaf != NUL)
#  define USE_IMSTATUSFUNC (!gui.in_use && *p_imsf != NUL)
# else
#  define USE_IMACTIVATEFUNC (*p_imaf != NUL)
#  define USE_IMSTATUSFUNC (*p_imsf != NUL)
# endif
#endif

    void
im_set_position(int row, int col)
{
    // The pre-edit area is a popup window which is displayed by MMTextView.
    [[MMBackend sharedInstance] setPreEditRow:row column:col];
}


    void
im_set_control(int enable)
{
    // Tell frontend whether it should notify us when the input method changes
    // or not (called when 'imd' is toggled).
    int msgid = enable ? EnableImControlMsgID : DisableImControlMsgID;
    [[MMBackend sharedInstance] queueMessage:msgid properties:nil];
}


    void
im_set_active(int active)
{
#if defined(FEAT_EVAL)
    if (USE_IMACTIVATEFUNC)
    {
        if (active != im_get_status())
            call_imactivatefunc(active);
        return;
    }
#endif

    // Don't enable IM if imdisableactivate is true.
    if (p_imdisableactivate && active)
        return;

    // Tell frontend to enable/disable IM (called e.g. when the mode changes).
    if (!p_imdisable) {
        int msgid = active ? ActivateKeyScriptMsgID : DeactivateKeyScriptMsgID;
        [[MMBackend sharedInstance] setImState:active];
        [[MMBackend sharedInstance] queueMessage:msgid properties:nil];
    }
}


    int
im_get_status(void)
{
#if defined(FEAT_EVAL)
    if (USE_IMSTATUSFUNC)
        return call_imstatusfunc();
#endif
    return [[MMBackend sharedInstance] imState];
}




// -- Find & Replace dialog -------------------------------------------------

#ifdef FIND_REPLACE_DIALOG

    static void
macvim_find_and_replace(char_u *arg, BOOL replace UNUSED)
{
    // TODO: Specialized dialog for find without replace?
    int wholeWord = FALSE;
    int matchCase = !p_ic;
    char_u *text  = get_find_dialog_text(arg, &wholeWord, &matchCase);

    int flags = 0;
    if (wholeWord) flags |= FRD_WHOLE_WORD;
    if (matchCase) flags |= FRD_MATCH_CASE;

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSString stringWithVimString:text],    @"text",
            [NSNumber numberWithInt:flags],         @"flags",
            nil];

    [[MMBackend sharedInstance] queueMessage:ShowFindReplaceDialogMsgID
                                  properties:args];
}

    void
gui_mch_find_dialog(exarg_T *eap)
{
    macvim_find_and_replace(eap->arg, NO);
}

    void
gui_mch_replace_dialog(exarg_T *eap)
{
    macvim_find_and_replace(eap->arg, YES);
}

#endif // FIND_REPLACE_DIALOG




// -- Unsorted --------------------------------------------------------------


    void
ex_macaction(exarg_T *eap)
{
    if (!gui.in_use) {
        emsg(_("E9000-M: Command only available in GUI mode"));
        return;
    }

    char_u *arg = eap->arg;
    arg = CONVERT_TO_UTF8(arg);

    NSDictionary *actionDict = [[MMBackend sharedInstance] actionDict];
    NSString *name = [NSString stringWithUTF8String:(char*)arg];
    if (actionDict && [actionDict objectForKey:name] != nil) {
        [[MMBackend sharedInstance] executeActionWithName:name];
    } else {
        semsg(_("E9001-M: Invalid action: %s"), eap->arg);
    }

    arg = CONVERT_TO_UTF8(arg);
}


/*
 * Adjust gui.char_height (after 'linespace' was changed).
 */
    int
gui_mch_adjust_charheight(void)
{
    [[MMBackend sharedInstance] adjustLinespace:p_linespace];
    return OK;
}


/*
 * Adjust gui.char_width (after 'columnspace' was changed).
 */
    int
gui_mch_adjust_charwidth(void)
{
    [[MMBackend sharedInstance] adjustColumnspace:p_columnspace];
    return OK;
}

    void
gui_mch_calc_cell_size(struct cellsize *cs_out)
{
    NSSize cellsize = [MMBackend sharedInstance].cellSize;
    cs_out->cs_xpixel = round(cellsize.width);
    cs_out->cs_ypixel = round(cellsize.height);
}


    void
gui_mch_beep(void)
{
    NSBeep();
}



#ifdef FEAT_BROWSE
/*
 * Pop open a file browser and return the file selected, in allocated memory,
 * or NULL if Cancel is hit.
 *  saving  - TRUE if the file will be saved to, FALSE if it will be opened.
 *  title   - Title message for the file browser dialog.
 *  dflt    - Default name of file.
 *  ext     - Default extension to be added to files without extensions.
 *  initdir - directory in which to open the browser (NULL = current dir)
 *  filter  - Filter for matched files to choose from.
 *  Has a format like this:
 *  "C Files (*.c)\0*.c\0"
 *  "All Files\0*.*\0\0"
 *  If these two strings were concatenated, then a choice of two file
 *  filters will be selectable to the user.  Then only matching files will
 *  be shown in the browser.  If NULL, the default allows all files.
 *
 *  *NOTE* - the filter string must be terminated with TWO nulls.
 */
    char_u *
gui_mch_browse(
    int saving,
    char_u *title,
    char_u *dflt,
    char_u *ext,
    char_u *initdir,
    char_u *filter)
{
    ASLogDebug(@"saving=%d title='%s' dflt='%s' ext='%s' initdir='%s' "
               "filter='%s'", saving, title, dflt, ext, initdir, filter);

    // Ensure no data is on the output queue before presenting the dialog.
    gui_macvim_force_flush();

    NSMutableDictionary *attr = [NSMutableDictionary
        dictionaryWithObject:[NSNumber numberWithBool:saving]
                      forKey:@"saving"];
    if (initdir)
        [attr setObject:[NSString stringWithVimString:initdir] forKey:@"dir"];

    char_u *s = (char_u*)[[MMBackend sharedInstance]
                            browseForFileWithAttributes:attr];

    return s;
}

/*
 * Put up a directory selector
 * Returns the selected name in allocated memory, or NULL for Cancel.
 * title			title for the window (UNUSED)
 * initdir			initial directory, NULL for current dir
 */
    char_u *
gui_mch_browsedir(
	       char_u *title,
	       char_u *initdir)
{
    ASLogDebug(@"title='%s' initdir='%s'", title, initdir);

    // Ensure no data is on the output queue before presenting the dialog.
    gui_macvim_force_flush();

    NSMutableDictionary *attr = [NSMutableDictionary
        dictionaryWithObject:[NSNumber numberWithBool:YES]
                      forKey:@"browsedir"];
    if (initdir)
        [attr setObject:[NSString stringWithVimString:initdir] forKey:@"dir"];

    char_u *s = (char_u*)[[MMBackend sharedInstance]
                            browseForFileWithAttributes:attr];

    return s;
}
#endif /* FEAT_BROWSE */



    int
gui_mch_dialog(
    int		type,
    char_u	*title,
    char_u	*message,
    char_u	*buttons,
    int		dfltbutton,
    char_u	*textfield,
    int		ex_cmd UNUSED)
{
    ASLogDebug(@"type=%d title='%s' message='%s' buttons='%s' dfltbutton=%d "
               "textfield='%s'", type, title, message, buttons, dfltbutton,
               textfield);

    // Ensure no data is on the output queue before presenting the dialog.
    gui_macvim_force_flush();

    int style = NSAlertStyleInformational;
    if (VIM_WARNING == type) style = NSAlertStyleWarning;
    else if (VIM_ERROR == type) style = NSAlertStyleCritical;

    NSMutableDictionary *attr = [NSMutableDictionary
                        dictionaryWithObject:[NSNumber numberWithInt:style]
                                      forKey:@"alertStyle"];

    if (buttons) {
        // 'buttons' is a string of '\n'-separated button titles 
        NSString *string = [NSString stringWithVimString:buttons];
        NSArray *array = [string componentsSeparatedByString:@"\n"];
        [attr setObject:array forKey:@"buttonTitles"];
    }

    NSString *messageText = nil;
    if (title)
        messageText = [NSString stringWithVimString:title];

    if (message) {
        NSString *informativeText = [NSString stringWithVimString:message];
        if (!messageText) {
            // HACK! If there is a '\n\n' or '\n' sequence in the message, then
            // make the part up to there into the title.  We only do this
            // because Vim has lots of dialogs without a title and they look
            // ugly that way.
            // TODO: Fix the actual dialog texts.
            NSRange eolRange = [informativeText rangeOfString:@"\n\n"];
            if (NSNotFound == eolRange.location)
                eolRange = [informativeText rangeOfString:@"\n"];
            if (NSNotFound != eolRange.location) {
                messageText = [informativeText substringToIndex:
                                                        eolRange.location];
                informativeText = [informativeText substringFromIndex:
                                                        NSMaxRange(eolRange)];
            }
        }

        [attr setObject:informativeText forKey:@"informativeText"];
    }

    if (messageText)
        [attr setObject:messageText forKey:@"messageText"];

    if (textfield) {
        NSString *string = [NSString stringWithVimString:textfield];
        [attr setObject:string forKey:@"textFieldString"];
    }

    return [[MMBackend sharedInstance] showDialogWithAttributes:attr
                                                    textField:(char*)textfield];
}


    void
gui_mch_flash(int msec UNUSED)
{
    // NOP
}


/*
 * Return the Pixel value (color) for the given color name.  This routine was
 * pretty much taken from example code in the Silicon Graphics OSF/Motif
 * Programmer's Guide.
 * Return INVALCOLOR when failed.
 */
    guicolor_T
gui_mch_get_color(char_u *name)
{
    guicolor_T color = gui_get_color_cmn(name);
    if (color != INVALCOLOR)
        return color;

    if (![MMBackend sharedInstance])
	return INVALCOLOR;

    char_u *u8name = CONVERT_TO_UTF8(name);

    NSString *key = [NSString stringWithUTF8String:(char*)u8name];
    color = [[MMBackend sharedInstance] lookupColorWithKey:key];

    CONVERT_TO_UTF8_FREE(u8name);
    return color;
}


/*
 * Return the RGB value of a pixel as long.
 */
    guicolor_T
gui_mch_get_rgb(guicolor_T pixel)
{
    // This is only implemented so that vim can guess the correct value for
    // 'background' (which otherwise defaults to 'dark'); it is not used for
    // anything else (as far as I know).
    // The implementation is simple since colors are stored in an int as
    // "rrggbb".
    return pixel;
}


    guicolor_T
gui_mch_get_rgb_color(int r, int g, int b)
{
    return gui_get_rgb_color_cmn(r, g, b);
}


/*
 * Get the screen dimensions.
 * Allow 10 pixels for horizontal borders, 40 for vertical borders.
 * Is there no way to find out how wide the borders really are?
 * TODO: Add live udate of those value on suspend/resume.
 */
    void
gui_mch_get_screen_dimensions(int *screen_w, int *screen_h)
{
    ASLogDebug(@"Columns=%ld Rows=%ld", Columns, Rows);
    *screen_w = Columns;
    *screen_h = Rows;
}


/*
 * Return OK if the key with the termcap name "name" is supported.
 */
    int
gui_mch_haskey(char_u *name)
{
    return [[MMBackend sharedInstance] hasSpecialKeyWithValue:name];
}


/*
 * Iconify the GUI window.
 */
    void
gui_mch_iconify(void)
{
    // NOP
}


#if defined(FEAT_EVAL) || defined(PROTO)
/*
 * Bring the Vim window to the foreground.
 */
    void
gui_mch_set_foreground(void)
{
    [[MMBackend sharedInstance] activate];
}
#endif



    void
gui_mch_set_shellsize(
    int		width,
    int		height,
    int		min_width,
    int		min_height,
    int		base_width,
    int		base_height,
    int		direction)
{
    ASLogDebug(@"width=%d height=%d min_width=%d min_height=%d base_width=%d "
               "base_height=%d direction=%d", width, height, min_width,
               min_height, base_width, base_height, direction);
    [[MMBackend sharedInstance] setRows:height columns:width];
}


/*
 * Re-calculates size of the Vim view to fit within the window without having
 * to resize the window. Usually happens after UI elements have changed (e.g.
 * adding / removing a toolbar) when guioptions 'k' is set.
 *
 * In other GVim implementations this is a synchronous operation (via
 * gui_mch_newfont). In MacVim we need to request the GUI process to resize us,
 * and we do this asynchronously to avoid introducing sync points. It does mean
 * Vim will temporarily draw/behave using the old size until the it receives
 * the resize message from the GUI.
 */
    void
gui_mch_resize_view(void)
{
    [[MMBackend sharedInstance] resizeView];
}


/*
 * Set the position of the top left corner of the window to the given
 * coordinates.
 */
    void
gui_mch_set_winpos(int x, int y)
{
    [[MMBackend sharedInstance] setWindowPositionX:x Y:y];
}


/*
 * Get the position of the top left corner of the window.
 */
    int
gui_mch_get_winpos(int *x, int *y)
{
    [[MMBackend sharedInstance] getWindowPositionX:x Y:y];
    return OK;
}


    void
gui_mch_set_text_area_pos(int x UNUSED, int y UNUSED, int w UNUSED, int h UNUSED)
{
    // NOP
}


/*
 * Set the window title and icon.
 * (The icon is not taken care of).
 */
    void
gui_mch_settitle(char_u *title, char_u *icon)
{
    ASLogDebug(@"title='%s' icon='%s'", title, icon);

    title = CONVERT_TO_UTF8(title);

    MMBackend *backend = [MMBackend sharedInstance];
    [backend setWindowTitle:(char*)title];

    // TODO: Convert filename to UTF-8?
    if (curbuf)
        [backend setDocumentFilename:(char*)curbuf->b_ffname];

    CONVERT_TO_UTF8_FREE(title);
}


    void
gui_mch_toggle_tearoffs(int enable UNUSED)
{
    // NOP
}



    void
gui_mch_enter_fullscreen(guicolor_T bg)
{
    [[MMBackend sharedInstance] enterFullScreen:fuoptions_flags background:bg];
}


    void
gui_mch_leave_fullscreen(void)
{
    [[MMBackend sharedInstance] leaveFullScreen];
}


    void
gui_mch_fuopt_update(void)
{
    if (!gui.in_use)
        return;
    if (!p_fullscreen)
        return;

    guicolor_T fg, bg;
    if (fuoptions_flags & FUOPT_BGCOLOR_HLGROUP) {
        syn_id2colors(fuoptions_bgcolor, &fg, &bg);
    } else {
        bg = fuoptions_bgcolor;
    }

    [[MMBackend sharedInstance] setFullScreenBackgroundColor:bg];
}


    void
gui_macvim_update_modified_flag(void)
{
    [[MMBackend sharedInstance] updateModifiedFlag];
}

/*
 * Add search pattern 'pat' to the OS X find pasteboard.  This allows other
 * apps access the last pattern searched for (hitting <D-g> in another app will
 * initiate a search for the same pattern).
 */
    void
gui_macvim_add_to_find_pboard(char_u *pat)
{
    if (!pat) return;

	if ([MMBackend sharedInstance].addToFindPboardOverride) {
		// MMBackend would set addToFindPboardOverride to YES when we are
		// using the useSelectionFodFind: macaction, accessible via Cmd-E,
		// which indicates we always want to share to the find pasteboard
		// unlike normal search. Since this function is called after the action
		// is handled we need to manually clear the override so it doesn't
		// persist in later searches.
		[[MMBackend sharedInstance] clearAddToFindPboardOverride];
	} else {
		if (!MMShareFindPboard) {
			return;
		}
	}

    pat = CONVERT_TO_UTF8(pat);
    NSString *s = [NSString stringWithUTF8String:(char*)pat];
    CONVERT_TO_UTF8_FREE(pat);

    if (!s) return;

    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSPasteboardNameFind];
    NSArray *supportedTypes = [NSArray arrayWithObjects:VimFindPboardType,
            NSPasteboardTypeString, nil];
    [pb declareTypes:supportedTypes owner:nil];

    // Put two entries on the Find pasteboard:
    //   * the pattern Vim uses
    //   * same as above but with some backslash escaped characters removed
    // The second entry will be used by other applications when taking entries
    // off the Find pasteboard, whereas MacVim will use the first if present.
    [pb setString:s forType:VimFindPboardType];
    [pb setString:[s stringByRemovingFindPatterns] forType:NSPasteboardTypeString];
}

    void
gui_macvim_set_antialias(int antialias)
{
    [[MMBackend sharedInstance] setAntialias:antialias];
}

    void
gui_macvim_set_ligatures(int ligatures)
{
    [[MMBackend sharedInstance] setLigatures:ligatures];
}
    void
gui_macvim_set_thinstrokes(int thinStrokes)
{
    [[MMBackend sharedInstance] setThinStrokes:thinStrokes];
}

    void
gui_macvim_wait_for_startup(void)
{
    MMBackend *backend = [MMBackend sharedInstance];
    if ([backend waitForAck])
        [backend waitForConnectionAcknowledgement];
}

    void
gui_macvim_get_window_layout(int *count, int *layout)
{
    if (!(count && layout)) return;

    // NOTE: Only set 'layout' if the backend has requested a != 0 layout, else
    // any command line arguments (-p/-o) would be ignored.
    int window_layout = [[MMBackend sharedInstance] initialWindowLayout];
    if (window_layout > 0 && window_layout < 4) {
        // The window_layout numbers must match the WIN_* defines in main.c.
        *count = 0;
        *layout = window_layout;
    }
}

    void *
gui_macvim_new_autoreleasepool(void)
{
    return (void *)[[NSAutoreleasePool alloc] init];
}

    void
gui_macvim_release_autoreleasepool(void *pool)
{
    [(id)pool release];
}

// -- Client/Server ---------------------------------------------------------

#ifdef MAC_CLIENTSERVER

//
// NOTE: Client/Server is only fully supported with a GUI.  Theoretically it
// would be possible to make the server code work with terminal Vim, but it
// would require that a run-loop is set up and checked.  This should not be
// difficult to implement, simply call gui_mch_update() at opportune moments
// and it will take care of the run-loop.  Another (bigger) problem with
// supporting servers in terminal mode is that the server listing code talks to
// MacVim (the GUI) to figure out which servers are running.
//


/*
 * Register connection with 'name'.  The actual connection is named something
 * like 'org.vim.MacVim.VIM3', whereas the server is called 'VIM3'.
 */
    void
serverRegisterName(char_u *name)
{
    name = CONVERT_TO_UTF8(name);

    NSString *svrName = [NSString stringWithUTF8String:(char*)name];
    [[MMBackend sharedInstance] registerServerWithName:svrName];

    CONVERT_TO_UTF8_FREE(name);
}


/*
 * Send to an instance of Vim.
 * Returns 0 for OK, negative for an error.
 */
    int
serverSendToVim(
    char_u	*name,
    char_u	*cmd,
    char_u	**result,
    int		*port,
    int		asExpr,
    int		timeout UNUSED,
    int		silent)
{
    name = CONVERT_TO_UTF8(name);
    cmd = CONVERT_TO_UTF8(cmd);

    BOOL ok = [[MMBackend sharedInstance]
            sendToServer:[NSString stringWithUTF8String:(char*)name]
                  string:[NSString stringWithUTF8String:(char*)cmd]
                   reply:result
                    port:port
              expression:asExpr
                  silent:silent];

    CONVERT_TO_UTF8_FREE(name);
    CONVERT_TO_UTF8_FREE(cmd);

    return ok ? 0 : -1;
}


/*
 * Ask MacVim for the names of all Vim servers.
 */
    char_u *
serverGetVimNames(void)
{
    char_u *names = NULL;
    NSArray *list = [[MMBackend sharedInstance] serverList];

    if (list) {
        NSString *string = [list componentsJoinedByString:@"\n"];
        names = [string vimStringSave];
    }

    return names;
}


/*
 * 'str' is a hex int representing the send port of the connection.
 */
    int
serverStrToPort(char_u *str)
{
    int port = 0;

    sscanf((char *)str, "0x%x", &port);
    if (!port)
        semsg(_("E573: Invalid server id used: %s"), str);

    return port;
}


/*
 * Check for replies from server with send port 'port'.
 * Return TRUE and a non-malloc'ed string if there is.  Else return FALSE.
 */
    int
serverPeekReply(int port, char_u **str)
{
    NSString *reply = [[MMBackend sharedInstance] peekForReplyOnPort:port];
    int len = [reply lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    if (str && len > 0) {
        *str = (char_u*)[reply UTF8String];

        if (input_conv.vc_type != CONV_NONE) {
            char_u *s = string_convert(&input_conv, *str, &len);

            if (len > 0) {
                // HACK! Since 's' needs to be freed we cannot simply set
                // '*str = s' or memory will leak.  Instead, create a dummy
                // NSData and return its 'bytes' pointer, then autorelease the
                // NSData.
                NSData *data = [NSData dataWithBytes:s length:len+1];
                *str = (char_u*)[data bytes];
            }

            vim_free(s);
        }
    }

    return reply != nil;
}


/*
 * Wait for replies from server with send port 'port'.
 * Return 0 and the malloc'ed string when a reply is available.
 * Return -1 on error.
 */
    int
serverReadReply(int port, char_u **str, int timeout)
{
    NSString *reply = [[MMBackend sharedInstance] waitForReplyOnPort:port
							     timeout:timeout];
    if (reply && str) {
        *str = [reply vimStringSave];
        return 0;
    }

    return -1;
}


/*
 * Send a reply string (notification) to client with port given by "serverid".
 * Return -1 if the window is invalid.
 */
    int
serverSendReply(char_u *serverid, char_u *reply)
{
    int retval = -1;
    int port = serverStrToPort(serverid);
    if (port > 0 && reply) {
        reply = CONVERT_TO_UTF8(reply);
        BOOL ok = [[MMBackend sharedInstance]
                sendReply:[NSString stringWithUTF8String:(char*)reply]
                   toPort:port];
        retval = ok ? 0 : -1;
        CONVERT_TO_UTF8_FREE(reply);
    }

    return retval;
}

#endif // MAC_CLIENTSERVER




// -- ODB Editor Support ----------------------------------------------------

#ifdef FEAT_ODB_EDITOR
/*
 * The ODB Editor protocol works like this:
 * - An external program (the server) asks MacVim to open a file and associates
 *   three things with this file: (1) a server id (a four character code that
 *   identifies the server), (2) a path that can be used as window title for
 *   the file (optional), (3) an arbitrary token (optional)
 * - When a file is saved or closed, MacVim should tell the server about which
 *   file was modified and also pass back the token
 *
 * All communication between MacVim and the server goes via Apple Events.
 */

    static int16_t
odb_event(buf_T *buf, const AEEventID action)
{
    if (!(buf->b_odb_server_id && buf->b_ffname))
        return noErr;

    NSAppleEventDescriptor *targetDesc = [NSAppleEventDescriptor
            descriptorWithDescriptorType:typeApplSignature
                                   bytes:&buf->b_odb_server_id
                                  length:sizeof(uint32_t)];

    // TODO: Convert b_ffname to UTF-8?
    NSString *path = [NSString stringWithUTF8String:(char*)buf->b_ffname];
    NSData *pathData = [[[NSURL fileURLWithPath:path] absoluteString]
            dataUsingEncoding:NSUTF8StringEncoding];
    NSAppleEventDescriptor *pathDesc = [NSAppleEventDescriptor
            descriptorWithDescriptorType:typeFileURL data:pathData];

    NSAppleEventDescriptor *event = [NSAppleEventDescriptor
            appleEventWithEventClass:kODBEditorSuite
                             eventID:action
                    targetDescriptor:targetDesc
                            returnID:kAutoGenerateReturnID
                       transactionID:kAnyTransactionID];

    [event setParamDescriptor:pathDesc forKeyword:keyDirectObject];

    if (buf->b_odb_token)
        [event setParamDescriptor:buf->b_odb_token forKeyword:keySenderToken];

    return AESendMessage([event aeDesc], NULL, kAENoReply | kAENeverInteract,
            kAEDefaultTimeout);
}

    int16_t
odb_buffer_close(buf_T *buf)
{
    int16_t err = noErr;
    if (buf) {
        err = odb_event(buf, kAEClosedFile);

        buf->b_odb_server_id = 0;

        if (buf->b_odb_token) {
            [(NSAppleEventDescriptor *)(buf->b_odb_token) release];
            buf->b_odb_token = NULL;
        }

        if (buf->b_odb_fname) {
            vim_free(buf->b_odb_fname);
            buf->b_odb_fname = NULL;
        }
    }

    return err;
}

    int16_t
odb_post_buffer_write(buf_T *buf)
{
    return buf ? odb_event(buf, kAEModifiedFile) : noErr;
}

    void
odb_end(void)
{
    buf_T *buf;
    for (buf = firstbuf; buf != NULL; buf = buf->b_next)
        odb_buffer_close(buf);
}

#endif // FEAT_ODB_EDITOR


    char_u *
get_macaction_name(expand_T *xp UNUSED, int idx)
{
    static char_u *str = NULL;
    NSDictionary *actionDict = [[MMBackend sharedInstance] actionDict];

    if (nil == actionDict || idx < 0 || (size_t)idx >= [actionDict count])
        return NULL;

    NSString *string = [[actionDict allKeys] objectAtIndex:idx];
    if (!string)
        return NULL;

    char_u *plainStr = (char_u*)[string UTF8String];

    if (str) {
        vim_free(str);
        str = NULL;
    }
    if (input_conv.vc_type != CONV_NONE) {
        int len = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        str = string_convert(&input_conv, plainStr, &len);
        plainStr = str;
    }

    return plainStr;
}


    int
is_valid_macaction(char_u *action)
{
    int isValid = NO;
    NSDictionary *actionDict = [[MMBackend sharedInstance] actionDict];
    if (actionDict) {
        action = CONVERT_TO_UTF8(action);
        NSString *string = [NSString stringWithUTF8String:(char*)action];
        isValid = (nil != [actionDict objectForKey:string]);
        CONVERT_TO_UTF8_FREE(action);
    }

    return isValid;
}

    static int
specialKeyToNSKey(int key)
{
    if (!IS_SPECIAL(key))
        return key;

    static struct {
        int special;
        int nskey;
    } sp2ns[] = {
        { K_UP, NSUpArrowFunctionKey },
        { K_DOWN, NSDownArrowFunctionKey },
        { K_LEFT, NSLeftArrowFunctionKey },
        { K_RIGHT, NSRightArrowFunctionKey },
        { K_F1, NSF1FunctionKey },
        { K_F2, NSF2FunctionKey },
        { K_F3, NSF3FunctionKey },
        { K_F4, NSF4FunctionKey },
        { K_F5, NSF5FunctionKey },
        { K_F6, NSF6FunctionKey },
        { K_F7, NSF7FunctionKey },
        { K_F8, NSF8FunctionKey },
        { K_F9, NSF9FunctionKey },
        { K_F10, NSF10FunctionKey },
        { K_F11, NSF11FunctionKey },
        { K_F12, NSF12FunctionKey },
        { K_F13, NSF13FunctionKey },
        { K_F14, NSF14FunctionKey },
        { K_F15, NSF15FunctionKey },
        { K_F16, NSF16FunctionKey },
        { K_F17, NSF17FunctionKey },
        { K_F18, NSF18FunctionKey },
        { K_F19, NSF19FunctionKey },
        { K_F20, NSF20FunctionKey },
        { K_F21, NSF21FunctionKey },
        { K_F22, NSF22FunctionKey },
        { K_F23, NSF23FunctionKey },
        { K_F24, NSF24FunctionKey },
        { K_F25, NSF25FunctionKey },
        { K_F26, NSF26FunctionKey },
        { K_F27, NSF27FunctionKey },
        { K_F28, NSF28FunctionKey },
        { K_F29, NSF29FunctionKey },
        { K_F30, NSF30FunctionKey },
        { K_F31, NSF31FunctionKey },
        { K_F32, NSF32FunctionKey },
        { K_F33, NSF33FunctionKey },
        { K_F34, NSF34FunctionKey },
        { K_F35, NSF35FunctionKey },
        { K_DEL, NSBackspaceCharacter },
        { K_BS, NSDeleteCharacter },
        { K_HOME, NSHomeFunctionKey },
        { K_END, NSEndFunctionKey },
        { K_PAGEUP, NSPageUpFunctionKey },
        { K_PAGEDOWN, NSPageDownFunctionKey }
    };

    size_t i;
    for (i = 0; i < sizeof(sp2ns)/sizeof(sp2ns[0]); ++i) {
        if (sp2ns[i].special == key)
            return sp2ns[i].nskey;
    }

    return 0;
}

    static int
vimModMaskToEventModifierFlags(int mods)
{
    int flags = 0;

    if (mods & MOD_MASK_SHIFT)
        flags |= NSEventModifierFlagShift;
    if (mods & MOD_MASK_CTRL)
        flags |= NSEventModifierFlagControl;
    if (mods & MOD_MASK_ALT)
        flags |= NSEventModifierFlagOption;
    if (mods & MOD_MASK_CMD)
        flags |= NSEventModifierFlagCommand;

    return flags;
}



// -- Job and Channel Support ------------------------------------------------------

#if defined(FEAT_JOB_CHANNEL)
    void *
gui_macvim_add_channel(channel_T *channel, ch_part_T part)
{
    dispatch_source_t s =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                               channel->ch_part[part].ch_fd,
                               0,
                               dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{
        channel_may_read(channel, part, "gui_macvim_add_channel");
    });
    dispatch_resume(s);
    return s;
}

    void
gui_macvim_remove_channel(void *cookie)
{
    dispatch_source_t s = (dispatch_source_t)cookie;
    dispatch_source_cancel(s);
    dispatch_release(s);
}

    void
gui_macvim_cleanup_job_all(void)
{
    if (is_macos_high_sierra_or_later)
	job_cleanup_all();
}

#endif // FEAT_JOB_CHANNEL


// -- Graphical Sign Support ------------------------------------------------

#if defined(FEAT_SIGN_ICONS)
    void
gui_mch_drawsign(int row, int col, int typenr)
{
    if (!gui.in_use)
        return;

    NSString *imgName = (NSString *)sign_get_image(typenr);
    if (!imgName)
        return;

    const int txtSize = 2; // This is specified in the docs, and is expected to always be the case.

    [[MMBackend sharedInstance] drawSign:imgName
                                   atRow:row
                                  column:col
                                   width:txtSize
                                  height:1];
}

    void *
gui_mch_register_sign(char_u *signfile)
{
    if (!use_graphical_sign)
        return NULL;

    NSString *imgName = [NSString stringWithVimString:signfile];
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:imgName];
    if (!img) {
        emsg(_(e_couldnt_read_in_sign_data));
        return NULL;
    }

    [img release];

    return (void*)[imgName retain];
}

    void
gui_mch_destroy_sign(void *sign)
{
    NSString *imgName = (NSString *)sign;
    if (!imgName)
        return;

    [[MMBackend sharedInstance]
            queueMessage:DeleteSignMsgID
              properties:[NSDictionary dictionaryWithObjectsAndKeys:
                                                    imgName, @"imgName", nil]];
    [imgName release];
}

#endif // FEAT_SIGN_ICONS



// -- Balloon Eval Support ---------------------------------------------------

#ifdef FEAT_BEVAL

    BalloonEval *
gui_mch_create_beval_area(
    void	*target UNUSED,
    char_u	*mesg,
    void	(*mesgCB)(BalloonEval *, int),
    void	*clientData)
{
    BalloonEval	*beval;

    beval = (BalloonEval *)calloc(1, sizeof(BalloonEval));
    if (NULL == beval)
        return NULL;

    beval->msg = mesg;
    beval->msgCB = mesgCB;
    beval->clientData = clientData;

    return beval;
}

    void
gui_mch_enable_beval_area(BalloonEval *beval UNUSED)
{
    // NOP
}

    void
gui_mch_disable_beval_area(BalloonEval *beval UNUSED)
{
    // NOTE: An empty tool tip indicates that the tool tip window should hide.
    [[MMBackend sharedInstance] queueMessage:SetTooltipMsgID properties:
        [NSDictionary dictionaryWithObject:@"" forKey:@"toolTip"]];
}

/*
 * Show a balloon with "mesg".
 */
    void
gui_mch_post_balloon(BalloonEval *beval, char_u *mesg)
{
    vim_free(beval->msg);
    beval->msg = mesg == NULL ? NULL : vim_strsave(mesg);

    NSString *toolTip = [NSString stringWithVimString:mesg];
    [[MMBackend sharedInstance] setLastToolTip:toolTip];
}

#endif // FEAT_BEVAL

    void
gui_macvim_set_blur(int radius)
{
    [[MMBackend sharedInstance] setBlurRadius:radius];
}

    void
gui_macvim_set_background(int dark)
{
    [[MMBackend sharedInstance] setBackground:dark];
}

#pragma region MacVim builtin functions
#pragma mark MacVim builtin functions

/// Implementation of showdefinition()
void f_showdefinition(typval_T *argvars, typval_T *rettv UNUSED)
{
    if (!gui.in_use) {
        emsg(_("E9000-M: Command only available in GUI mode"));
        return;
    }

    if (in_vim9script() && check_for_string_arg(argvars, 0) == FAIL)
	return;

    char_u *lookup_text = tv_get_string(&argvars[0]);

    varnumber_T screen_row = -1;
    varnumber_T screen_col = -1;

    if (argvars[1].v_type == VAR_DICT) {
        // Retrieve the optional row/col from the caller. Note that this is
        // designed so that the input object could just be the output of
        // screenpos().
	dict_T	    *d = argvars[1].vval.v_dict;
        if (d != NULL) {
            screen_row = dict_get_number_def(d, "row", -1);
            screen_col = dict_get_number_def(d, "col", -1);
        }
    }

    if (screen_row <= 0 || screen_col <= 0) {
        // row/col are optional parameters, so if not given we just use the
        // cursor position.
        // We are essentially doing the following:
        //   var curpos = getcurpos()
        //   var screenpos = screenpos(win_getid(), curpos[1], curpos[2])
        //   showDefinition(text, screenpos['row'], screenpos['col'])
        //
        // Note that we could either take screenpos['cursorcol'] or
        // screenpos['col']. Both could make sense in some situations, but just
        // for consistency with how this function is used, we just use 'col'.
        // (It's consistent because this function is designed so that you can
        // just pass the output of screenpos() directly into the 2nd argument).
        varnumber_T lnum = 0, col = 0;
        {
            typval_T arg_winid_unknown;
            init_tv(&arg_winid_unknown);
            arg_winid_unknown.v_type = VAR_UNKNOWN;

            typval_T args[1] = { arg_winid_unknown };

            typval_T lrettv;

            f_getcurpos(args, &lrettv);
            if (lrettv.v_type == VAR_LIST) {
                lnum = list_find(lrettv.vval.v_list, 1)->li_tv.vval.v_number;
                col = list_find(lrettv.vval.v_list, 2)->li_tv.vval.v_number;
                list_unref(lrettv.vval.v_list);
            }
        }
        {
            typval_T arg_winid;
            init_tv(&arg_winid);
            arg_winid.v_type = VAR_NUMBER;
            arg_winid.vval.v_number = curwin->w_id;

            typval_T arg_lnum;
            init_tv(&arg_lnum);
            arg_lnum.v_type = VAR_NUMBER;
            arg_lnum.vval.v_number = lnum;

            typval_T arg_col;
            init_tv(&arg_col);
            arg_col.v_type = VAR_NUMBER;
            arg_col.vval.v_number = col;

            typval_T args[3] = {
                arg_winid,
                arg_lnum,
                arg_col,
            };
            typval_T lrettv;

            f_screenpos(args, &lrettv);

            screen_row = dict_get_number_def(lrettv.vval.v_dict, "row", -1);
            screen_col = dict_get_number_def(lrettv.vval.v_dict, "col", -1);

            dict_unref(lrettv.vval.v_dict);
        }
    }

    NSString *lookup_text_str = [NSString stringWithVimString:lookup_text];
    [[MMBackend sharedInstance] showDefinition:lookup_text_str
                                           row:screen_row
                                           col:screen_col];
}

#pragma endregion


// -- Netbeans Integration Support -------------------------------------------

#if defined(FEAT_NETBEANS_INTG) || defined(PROTO)
    void
netbeans_draw_multisign_indicator(int row UNUSED)
{
    // NOP
}
#endif // FEAT_NETBEANS_INTG
