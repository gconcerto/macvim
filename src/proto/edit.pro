/* edit.c */
int edit(int cmdchar, int startln, long count);
int ins_need_undo_get(void);
void ins_redraw(int ready);
void edit_putchar(int c, int highlight);
void set_insstart(linenr_T lnum, int col);
void edit_unputchar(void);
void display_dollar(colnr_T col);
void undisplay_dollar(void);
void truncate_spaces(char_u *line);
void backspace_until_column(int col);
int get_literal(int noReduceKeys);
void insertchar(int c, int flags, int second_indent);
void start_arrow(pos_T *end_insert_pos);
int stop_arrow(void);
void set_last_insert(int c);
void free_last_insert(void);
char_u *add_char2buf(int c, char_u *s);
void beginline(int flags);
int oneright(void);
int oneleft(void);
int cursor_up(long n, int upd_topline);
int cursor_down(long n, int upd_topline);
int stuff_inserted(int c, long count, int no_esc);
char_u *get_last_insert(void);
char_u *get_last_insert_save(void);
void replace_push(int c);
int replace_push_mb(char_u *p);
void replace_join(int off);
int hkmap(int c);
int bracketed_paste(paste_mode_T mode, int drop, garray_T *gap);
void ins_scroll(void);
void ins_horscroll(void);
int ins_eol(int c);
int ins_copychar(linenr_T lnum);
colnr_T get_nolist_virtcol(void);
int get_can_cindent(void);
void set_can_cindent(int val);
int ins_apply_autocmds(event_T event);
/* vim: set ft=c : */
