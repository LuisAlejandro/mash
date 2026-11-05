//! Shared visual frame for the first-launch wizard. Herdr is not running yet,
//! so the sidebar is a page index drawn with the same palette, not Herdr UI.
use crate::i18n;
// ponytail: these are today's bundled Herdr colors, not live user overrides;
// read config.toml only if wizard theming needs to follow custom themes.
use ratatui::{
    crossterm::event::{Event, MouseButton, MouseEventKind},
    layout::{Alignment, Constraint, Layout, Margin, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph, Wrap},
    Frame,
};
use std::cell::{Cell, RefCell};

// What the last draw put on screen and where, so a click maps to the same
// row the user sees. Each draw clears it; pages register targets while
// drawing, so hit areas can never drift from the rendered layout.
thread_local! {
    static TARGETS: RefCell<Vec<(Rect, usize)>> = const { RefCell::new(Vec::new()) };
    static LIGHT: Cell<bool> = const { Cell::new(false) };
}

/// Show the wizard in the light theme. Pages paint with the dark constants
/// below and `finish` translates the frame, so a page never needs to know
/// which theme is on.
pub fn set_light(light: bool) {
    LIGHT.with(|cell| cell.set(light));
}

// Dark colour -> light colour. The light side is Mash's own light theme as it
// ships elsewhere: Herdr's [theme.custom] light values and the Ghostty
// "Monokai Cursor Light" theme, so the wizard matches what setup opens into.
const LIGHT_PALETTE: [(Color, Color); 11] = [
    (TEXT, Color::Rgb(0x27, 0x28, 0x22)),
    (MUTED, Color::Rgb(0x6b, 0x67, 0x56)),
    (YELLOW, Color::Rgb(0x8a, 0x64, 0x00)),
    (RED, Color::Rgb(0xc4, 0x26, 0x5e)),
    (GREEN, Color::Rgb(0x4f, 0x72, 0x00)),
    (PANEL, Color::Rgb(0xf0, 0xef, 0xe8)),
    (SURFACE, Color::Rgb(0xe2, 0xe1, 0xd8)),
    (BACKGROUND, Color::Rgb(0xfa, 0xfa, 0xf7)),
    (ACCENT, Color::Rgb(0x3e, 0x3d, 0x32)),
    (ACTIVE_ROW, Color::Rgb(0xe6, 0xe4, 0xd6)),
    // The Mash logo's grey letters, from header-art.ansi; its reds read on both.
    (Color::Rgb(170, 170, 170), Color::Rgb(0x6b, 0x67, 0x56)),
];

fn to_light(color: Color, unset: Color) -> Color {
    if color == Color::Reset {
        // Cells left to the terminal default would otherwise show the dark
        // terminal's colours whenever its own theme was not switched too.
        return unset;
    }
    LIGHT_PALETTE
        .iter()
        .find_map(|(dark, light)| (*dark == color).then_some(*light))
        .unwrap_or(color)
}

/// Translate the finished frame into the current theme. Call once per draw,
/// after every page and overlay has painted.
pub fn finish(frame: &mut Frame) {
    if !LIGHT.with(Cell::get) {
        return;
    }
    let text = to_light(TEXT, TEXT);
    let background = to_light(BACKGROUND, BACKGROUND);
    for cell in frame.buffer_mut().content.iter_mut() {
        cell.fg = to_light(cell.fg, text);
        cell.bg = to_light(cell.bg, background);
    }
}

/// Sentinel ids for the shared shell: the sidebar index and the scroll wheel.
pub const SIDEBAR_BASE: usize = usize::MAX / 2;

pub fn clear_targets() {
    TARGETS.with(|targets| targets.borrow_mut().clear());
}

pub fn target(area: Rect, id: usize) {
    if area.width > 0 && area.height > 0 {
        TARGETS.with(|targets| targets.borrow_mut().push((area, id)));
    }
}

/// The target id under a left click, if any. Later registrations win, so a
/// button drawn over a row takes precedence.
pub fn clicked(event: &Event) -> Option<usize> {
    let Event::Mouse(mouse) = event else {
        return None;
    };
    if mouse.kind != MouseEventKind::Down(MouseButton::Left) {
        return None;
    }
    TARGETS.with(|targets| {
        targets.borrow().iter().rev().find_map(|(area, id)| {
            (mouse.column >= area.x
                && mouse.column < area.right()
                && mouse.row >= area.y
                && mouse.row < area.bottom())
            .then_some(*id)
        })
    })
}

/// -1 for wheel up, +1 for wheel down, so pages can move focus with it.
pub fn wheel(event: &Event) -> Option<isize> {
    match event {
        Event::Mouse(mouse) if mouse.kind == MouseEventKind::ScrollUp => Some(-1),
        Event::Mouse(mouse) if mouse.kind == MouseEventKind::ScrollDown => Some(1),
        _ => None,
    }
}

/// Lay out `lines` exactly as `Paragraph::wrap` renders them in `area` and
/// register a click target for every line that carries an id.
pub fn form_targets(area: Rect, lines: &[(Line<'static>, Option<usize>)], trim: bool) -> Vec<Rect> {
    let mut row = area.y;
    let mut rows = Vec::new();
    for (line, id) in lines {
        if row >= area.bottom() {
            break;
        }
        let height = Paragraph::new(line.clone())
            .wrap(Wrap { trim })
            .line_count(area.width)
            .max(1) as u16;
        let height = height.min(area.bottom() - row);
        let rect = Rect::new(area.x, row, area.width, height);
        if let Some(id) = id {
            target(rect, *id);
        }
        rows.push(rect);
        row += height;
    }
    rows
}

/// Register one target per span of a centred single-line footer, using the
/// same centring Paragraph applies.
pub fn button_targets(area: Rect, spans: &[(Span<'static>, Option<usize>)]) {
    let total: u16 = spans.iter().map(|(span, _)| span.width() as u16).sum();
    let mut x = area.x + area.width.saturating_sub(total) / 2;
    for (span, id) in spans {
        let width = span.width() as u16;
        if let Some(id) = id {
            target(Rect::new(x, area.y, width, area.height.min(1)), *id);
        }
        x += width;
    }
}

/// Render the same rows used to register mouse targets, including wraps.
pub fn render_form(
    frame: &mut Frame,
    area: Rect,
    mut lines: Vec<(Line<'static>, Option<usize>)>,
    trim: bool,
) {
    // Scroll whole wrapped rows, so drawing and mouse targets stay identical.
    if let Some(focus) = lines.iter().rposition(|(line, _)| {
        line.style.bg == Some(ACTIVE_ROW)
            || line
                .spans
                .iter()
                .any(|span| span.style.bg == Some(ACTIVE_ROW) || span.style.fg == Some(RED))
    }) {
        let heights: Vec<_> = lines[..=focus]
            .iter()
            .map(|(line, _)| {
                Paragraph::new(line.clone())
                    .wrap(Wrap { trim })
                    .line_count(area.width)
                    .max(1)
            })
            .collect();
        let mut height: usize = heights.iter().sum();
        let mut start = 0;
        while height > area.height as usize && start < focus {
            height -= heights[start];
            start += 1;
        }
        lines.drain(..start);
    }
    let rows = form_targets(area, &lines, trim);
    for ((line, _), row) in lines.iter().zip(&rows) {
        // Text inputs mark their value span; checkboxes, radios and dropdown
        // options mark the whole line. Paint empty cells too, so focus and the
        // menu surface remain visible beyond the printed label.
        let background = if let Some(color) = line.style.bg {
            Some((0, color))
        } else {
            line.spans
                .iter()
                .position(|span| span.style.bg == Some(ACTIVE_ROW))
                .map(|index| {
                    (
                        line.spans[..index].iter().map(Span::width).sum::<usize>() as u16,
                        ACTIVE_ROW,
                    )
                })
        };
        if let Some((start, color)) = background.filter(|(start, _)| *start < row.width) {
            fill(
                frame,
                Rect::new(row.x + start, row.y, row.width - start, 1),
                color,
            );
            if row.height > 1 {
                fill(
                    frame,
                    Rect::new(row.x, row.y + 1, row.width, row.height - 1),
                    color,
                );
            }
        }
    }
    frame.render_widget(
        Paragraph::new(lines.into_iter().map(|(line, _)| line).collect::<Vec<_>>())
            .wrap(Wrap { trim }),
        area,
    );
}

pub fn render_buttons(frame: &mut Frame, area: Rect, spans: &[(Span<'static>, Option<usize>)]) {
    let actions = footer(frame, area);
    button_targets(actions, spans);
    frame.render_widget(
        Paragraph::new(Line::from(
            spans
                .iter()
                .map(|(span, _)| span.clone())
                .collect::<Vec<_>>(),
        ))
        .alignment(Alignment::Center),
        actions,
    );
}

pub const TEXT: Color = Color::Rgb(214, 214, 212); // Herdr theme.custom.text
pub const MUTED: Color = Color::Rgb(153, 153, 153); // overlay0
pub const YELLOW: Color = Color::Rgb(230, 219, 116); // mauve / Monokai yellow
pub const RED: Color = Color::Rgb(249, 38, 114); // Monokai red
pub const GREEN: Color = Color::Rgb(166, 226, 46); // Monokai green
pub const PANEL: Color = Color::Rgb(30, 31, 28); // sidebar_bg and panel_bg
pub const SURFACE: Color = Color::Rgb(52, 53, 47); // surface0, for section headers
const BACKGROUND: Color = Color::Rgb(39, 40, 34); // Ghostty's Monokai Cursor
const ACCENT: Color = Color::Rgb(204, 204, 204);
const ACTIVE_ROW: Color = Color::Rgb(51, 51, 51);
pub const PAGES: [&str; 7] = [
    "Identity",
    "Tools",
    "Model provider",
    "Web search",
    "Memory",
    "Appearance",
    "Dictation",
];

pub const PAGE_COUNT: usize = PAGES.len();

pub fn page_title(title: &str, index: usize) -> String {
    i18n::t("wizard.shell.page_title")
        .replace("{title}", title)
        .replace("{current}", &(index + 1).to_string())
        .replace("{total}", &PAGE_COUNT.to_string())
}

pub fn page_label(index: usize) -> String {
    let (key, label) = match index {
        0 => ("wizard.identity.title", i18n::t("wizard.identity.title")),
        1 => ("wizard.tools.title", i18n::t("wizard.tools.title")),
        2 => (
            "wizard.page.model_provider",
            i18n::t("wizard.page.model_provider"),
        ),
        3 => ("wizard.page.web_search", i18n::t("wizard.page.web_search")),
        4 => ("wizard.page.memory", i18n::t("wizard.page.memory")),
        5 => ("wizard.font.title", i18n::t("wizard.font.title")),
        6 => ("wizard.voice.title", i18n::t("wizard.voice.title")),
        _ => return String::new(),
    };
    if label == key {
        PAGES[index].to_string()
    } else {
        label
    }
}

pub fn selected() -> Style {
    Style::default().fg(TEXT).bg(ACTIVE_ROW)
}

/// Advance within the visible fields. Each page chooses whether arrows wrap.
pub fn focus_step(current: usize, count: usize, direction: isize, wrap: bool) -> usize {
    if count == 0 {
        return 0;
    }
    let next = current as isize + direction;
    if wrap {
        next.rem_euclid(count as isize) as usize
    } else {
        next.clamp(0, count as isize - 1) as usize
    }
}

pub fn text_field(focused: bool, label: &str, value: String) -> Line<'static> {
    Line::from(vec![
        Span::styled(
            format!("{label}: "),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            value,
            if focused {
                selected()
            } else {
                Style::default()
            },
        ),
        Span::styled(
            if focused { "_" } else { "" },
            Style::default()
                .fg(YELLOW)
                .bg(if focused { ACTIVE_ROW } else { PANEL }),
        ),
    ])
}

pub fn checkbox(focused: bool, label: &str, checked: bool) -> Line<'static> {
    Line::from(vec![
        Span::styled(
            format!("[{}] ", if checked { "x" } else { " " }),
            Style::default().fg(if checked { GREEN } else { TEXT }),
        ),
        Span::styled(
            label.to_owned(),
            Style::default().add_modifier(Modifier::BOLD),
        ),
    ])
    .style(if focused {
        selected()
    } else {
        Style::default()
    })
}

pub fn button(focused: bool, label: &str) -> Span<'static> {
    Span::styled(
        label.to_owned(),
        (if focused {
            selected()
        } else {
            Style::default()
        })
        .add_modifier(Modifier::BOLD),
    )
}

fn fill(frame: &mut Frame, area: Rect, color: Color) {
    frame.render_widget(
        Block::default().style(Style::default().fg(TEXT).bg(color)),
        area,
    );
}

pub fn highlight(frame: &mut Frame, area: Rect) {
    fill(frame, area, ACTIVE_ROW);
}

/// Header and footer bands borrow Herdr's surface/panel contrast, not borders.
pub fn header(frame: &mut Frame, area: Rect, title: &str) {
    fill(frame, area, SURFACE);
    let row = Rect::new(
        area.x,
        area.y + area.height.saturating_sub(1) / 2,
        area.width,
        area.height.min(1),
    );
    frame.render_widget(
        Paragraph::new(title).alignment(Alignment::Center).style(
            Style::default()
                .fg(ACCENT)
                .bg(SURFACE)
                .add_modifier(Modifier::BOLD),
        ),
        row,
    );
}

pub fn footer(frame: &mut Frame, area: Rect) -> Rect {
    fill(frame, area, PANEL);
    Rect::new(
        area.x.saturating_add(1),
        area.y + area.height.saturating_sub(1) / 2,
        area.width.saturating_sub(2),
        area.height.min(1),
    )
}

/// Paint a section and return the inset area for its contents.
pub fn section(frame: &mut Frame, area: Rect, title: &str) -> Rect {
    fill(frame, area, PANEL);
    frame.render_widget(
        Paragraph::new(format!(" {title}")).style(Style::default().fg(MUTED).bg(PANEL)),
        Rect::new(area.x, area.y, area.width, area.height.min(1)),
    );
    area.inner(Margin {
        horizontal: 1,
        vertical: 1,
    })
}

// Wide enough for the 26-column Mash logo plus a column of panel either side.
const SIDEBAR_WIDTH: u16 = 30;
const LOGO_ROWS: u16 = 10;

// The logo needs its 10 rows plus SETUP, the page list and the hint; a short
// terminal falls back to the one-line MASH title instead of clipping the list.
fn shows_logo(area: Rect) -> bool {
    area.height >= LOGO_ROWS + PAGE_COUNT as u16 + 8
}

/// Draw the common shell and return the form's rectangle. None means setup is
/// being applied after all setup pages have been completed.
pub fn page_area(frame: &mut Frame, page: Option<usize>) -> Rect {
    clear_targets();
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().fg(TEXT).bg(BACKGROUND)),
        area,
    );

    // The form needs width for URLs, masked keys and tool descriptions. On a
    // small terminal, keep it usable instead of squeezing it beside a sidebar.
    if area.width < 90 || area.height < 16 {
        let rows = Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).split(area);
        let title = page.map_or_else(
            || format!("Mash  ›  {}", i18n::t("wizard.shell.installing")),
            |index| {
                format!(
                    "Mash  ›  {} {}/{}  ›  {}",
                    i18n::t("wizard.shell.setup"),
                    index + 1,
                    PAGES.len(),
                    page_label(index)
                )
            },
        );
        frame.render_widget(
            Paragraph::new(title).style(Style::default().fg(TEXT).bg(SURFACE)),
            rows[0],
        );
        fill(frame, rows[1], BACKGROUND);
        return rows[1];
    }

    let columns = Layout::horizontal([
        Constraint::Length(SIDEBAR_WIDTH),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .split(area);
    let sidebar = columns[0];
    let content = columns[2];
    fill(frame, sidebar, PANEL);
    let inner = sidebar.inner(Margin {
        horizontal: 1,
        vertical: 1,
    });
    let mut lines = if shows_logo(area) {
        let mut art: Vec<Line> = crate::welcome_page::art_lines()
            .into_iter()
            .map(Line::centered)
            .collect();
        art.push(
            Line::styled(
                i18n::t("wizard.shell.setup_label"),
                Style::default().fg(MUTED),
            )
            .centered(),
        );
        art
    } else {
        vec![
            Line::styled(
                " MASH",
                Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
            ),
            Line::styled(
                format!(" {}", i18n::t("wizard.shell.setup_label")),
                Style::default().fg(MUTED),
            ),
        ]
    };
    lines.push(Line::default());
    let first_page = inner.y + lines.len() as u16;
    for index in 0..PAGES.len() {
        let label = page_label(index);
        let active = page == Some(index);
        let completed = page.is_none_or(|current| index < current);
        let marker = if active {
            ">"
        } else if completed {
            "✓"
        } else {
            " "
        };
        let row = format!(" {marker} {:02} {label}", index + 1);
        let style = if active {
            selected().add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(if completed { TEXT } else { MUTED })
        };
        lines.push(Line::styled(
            format!("{row:<width$}", width = inner.width as usize),
            style,
        ));
        // Only already-completed pages are clickable: going back is always
        // safe, while jumping forward would skip a page's validation.
        if page.is_some_and(|current| index < current) {
            target(
                Rect::new(inner.x, first_page + index as u16, inner.width, 1),
                SIDEBAR_BASE + index,
            );
        }
    }
    lines.push(Line::default());
    lines.push(Line::styled(
        if page.is_some() {
            i18n::t("wizard.shell.navigation_hint")
        } else {
            format!(" {}", i18n::t("wizard.shell.installing"))
        },
        Style::default().fg(MUTED),
    ));
    frame.render_widget(Paragraph::new(lines), inner);
    fill(frame, content, BACKGROUND);
    content
}

/// In a read-only preview, replace the normal form-navigation hint.
pub fn preview_hint(frame: &mut Frame) {
    let area = frame.area();
    if area.width >= 90 && area.height >= 16 {
        // Same rows page_area stacks: header, blank, page list, blank.
        let header = if shows_logo(area) { LOGO_ROWS + 1 } else { 2 };
        let width = SIDEBAR_WIDTH - 2;
        frame.render_widget(
            Paragraph::new(format!(
                "{:<width$}",
                format!(" {}", i18n::t("wizard.shell.preview_hint")),
                width = width as usize
            ))
            .style(Style::default().fg(MUTED).bg(PANEL)),
            Rect::new(
                area.x + 1,
                area.y + 1 + header + PAGE_COUNT as u16 + 2,
                width,
                1,
            ),
        );
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    fn luminance(color: Color) -> f64 {
        let Color::Rgb(r, g, b) = color else {
            panic!("{color:?} is not an RGB colour");
        };
        let channel = |value: u8| {
            let value = value as f64 / 255.0;
            if value <= 0.03928 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    fn contrast(a: Color, b: Color) -> f64 {
        let (a, b) = (luminance(a), luminance(b));
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    #[test]
    fn every_foreground_stays_readable_on_every_surface_in_both_themes() {
        let backgrounds = [PANEL, SURFACE, BACKGROUND, ACTIVE_ROW];
        let foregrounds = [TEXT, MUTED, YELLOW, RED, GREEN, ACCENT];
        for light in [false, true] {
            let shade = |color| if light { to_light(color, color) } else { color };
            for bg in backgrounds {
                for fg in foregrounds {
                    let ratio = contrast(shade(fg), shade(bg));
                    // Body text gets WCAG AA; accents and dimmed hints 3:1.
                    let floor = if fg == TEXT { 4.5 } else { 3.0 };
                    assert!(
                        ratio >= floor,
                        "light={light}: {fg:?} on {bg:?} is {ratio:.2}:1"
                    );
                }
            }
        }
    }

    #[test]
    fn the_light_theme_leaves_no_dark_colour_and_dark_is_untouched() {
        let draw = |light: bool| {
            set_light(light);
            let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
            terminal
                .draw(|frame| {
                    let form = page_area(frame, Some(2));
                    section(frame, form, "Section");
                    finish(frame);
                })
                .unwrap();
            set_light(false);
            terminal.backend().buffer().clone()
        };
        let dark = draw(false);
        let light = draw(true);
        let dark_colours: Vec<Color> = LIGHT_PALETTE.iter().map(|(dark, _)| *dark).collect();
        for cell in light.content() {
            assert!(
                !dark_colours.contains(&cell.bg),
                "dark background {:?} left",
                cell.bg
            );
            assert_ne!(cell.bg, Color::Reset);
            assert_ne!(cell.fg, Color::Reset);
        }
        // The sidebar logo, its grey letters included, and the panel colours.
        assert!(light
            .content()
            .iter()
            .any(|cell| cell.bg == Color::Rgb(0xf0, 0xef, 0xe8)));
        assert!(!light
            .content()
            .iter()
            .any(|cell| cell.fg == Color::Rgb(170, 170, 170)));
        // Dark draws are exactly what the pages painted.
        assert!(dark.content().iter().any(|cell| cell.bg == PANEL));
    }

    /// Position of the first on-screen cell where `needle` starts.
    pub fn find(buffer: &ratatui::buffer::Buffer, needle: &str) -> (u16, u16) {
        let area = buffer.area;
        for y in 0..area.height {
            let row: String = (0..area.width).map(|x| buffer[(x, y)].symbol()).collect();
            if let Some(byte) = row.find(needle) {
                return (row[..byte].chars().count() as u16, y);
            }
        }
        panic!("{needle:?} not on screen");
    }

    pub fn click(column: u16, row: u16) -> Event {
        use ratatui::crossterm::event::{KeyModifiers, MouseEvent};
        Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column,
            row,
            modifiers: KeyModifiers::NONE,
        })
    }

    #[test]
    fn shared_controls_keep_focus_and_click_targets_aligned() {
        assert_eq!(focus_step(0, 4, -1, true), 3);
        assert_eq!(focus_step(3, 4, 1, false), 3);
        assert_eq!(focus_step(0, 0, 1, true), 0);

        let mut terminal = Terminal::new(TestBackend::new(60, 8)).unwrap();
        terminal
            .draw(|frame| {
                clear_targets();
                fill(frame, Rect::new(0, 0, 60, 4), PANEL);
                render_form(
                    frame,
                    Rect::new(0, 0, 60, 4),
                    vec![
                        (text_field(true, "API key", "••••".into()), Some(4)),
                        (checkbox(true, "Install Skills", true), Some(5)),
                        (checkbox(false, "Install Programming Skills", true), Some(7)),
                        (text_field(true, "Email", String::new()), Some(8)),
                    ],
                    true,
                );
                render_buttons(
                    frame,
                    Rect::new(0, 5, 60, 3),
                    &[(button(true, " Continue "), Some(6))],
                );
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        for (label, id) in [
            ("API key", 4),
            ("Install Skills", 5),
            ("Install Programming Skills", 7),
            ("Email", 8),
            ("Continue", 6),
        ] {
            let (x, y) = find(buffer, label);
            assert_eq!(clicked(&click(x, y)), Some(id));
        }
        assert_eq!(buffer[(0, 0)].bg, PANEL); // label stays outside input
        assert_eq!(buffer[(9, 0)].bg, ACTIVE_ROW); // value starts after "API key: "
        assert_eq!(buffer[(59, 0)].bg, ACTIVE_ROW); // even blank cells show focus
        assert_eq!(buffer[(0, 1)].bg, ACTIVE_ROW); // checked row, including margin
        assert_eq!(buffer[(59, 1)].bg, ACTIVE_ROW);
        assert_eq!(buffer[(0, 2)].bg, PANEL); // unfocused checkbox
        assert_eq!(buffer[(59, 3)].bg, ACTIVE_ROW); // empty focused input
        assert!(!(0..4).any(|y| (0..60).any(|x| buffer[(x, y)].symbol() == ">")));
    }

    #[test]
    fn overflowing_forms_keep_the_focused_field_and_mouse_target_visible() {
        let mut terminal = Terminal::new(TestBackend::new(30, 3)).unwrap();
        terminal
            .draw(|frame| {
                clear_targets();
                let mut lines = vec![
                    (
                        Line::from("long introductory text that wraps over several rows"),
                        None
                    );
                    5
                ];
                lines.push((text_field(true, "Focused", "value".into()), Some(9)));
                render_form(frame, frame.area(), lines, true);
            })
            .unwrap();
        let (x, y) = find(terminal.backend().buffer(), "Focused");
        assert_eq!(clicked(&click(x, y)), Some(9));
    }

    #[test]
    fn wrapped_rows_get_targets_on_the_row_they_render_on() {
        let lines = vec![
            (Line::from("one two three four five six seven"), None),
            (Line::from("target"), Some(7)),
        ];
        let mut terminal = Terminal::new(TestBackend::new(10, 10)).unwrap();
        terminal
            .draw(|frame| {
                clear_targets();
                form_targets(frame.area(), &lines, true);
                frame.render_widget(
                    Paragraph::new(lines.iter().map(|(l, _)| l.clone()).collect::<Vec<_>>())
                        .wrap(Wrap { trim: true }),
                    frame.area(),
                );
            })
            .unwrap();
        let (x, y) = find(terminal.backend().buffer(), "target");
        assert!(y > 1, "first line must wrap for this test to mean anything");
        assert_eq!(clicked(&click(x, y)), Some(7));
        assert_eq!(clicked(&click(x, y - 1)), None);
    }

    #[test]
    fn page_split_exposes_seven_named_pages() {
        assert_eq!(
            PAGES,
            [
                "Identity",
                "Tools",
                "Model provider",
                "Web search",
                "Memory",
                "Appearance",
                "Dictation"
            ]
        );
        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        terminal
            .draw(|frame| {
                page_area(frame, Some(6));
            })
            .unwrap();
        find(terminal.backend().buffer(), "Setup 7/7");
    }

    #[test]
    fn only_completed_pages_in_the_sidebar_are_clickable() {
        let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
        terminal
            .draw(|frame| {
                page_area(frame, Some(2));
            })
            .unwrap();
        let buffer = terminal.backend().buffer().clone();
        let (x, y) = find(&buffer, "Identity");
        assert_eq!(clicked(&click(x, y)), Some(SIDEBAR_BASE));
        let (x, y) = find(&buffer, "Dictation");
        assert_eq!(clicked(&click(x, y)), None);
    }

    #[test]
    fn wide_terminal_has_a_highlighted_sidebar_and_form() {
        let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
        let mut form = Rect::default();
        terminal
            .draw(|frame| form = page_area(frame, Some(2)))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let text = buffer
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(text.contains("Identity"));
        assert!(text.contains("Memory"));
        assert_eq!(form.x, 31); // flush against the separator column
        assert_eq!((form.y, form.width, form.height), (0, 89, 30));
        // Logo rows 1-10, SETUP 11, blank 12, pages from 13: third page is 15.
        assert_eq!(buffer[(3, 15)].bg, ACTIVE_ROW);
        assert_eq!(buffer[(0, 15)].bg, PANEL);
        assert_eq!(buffer[(30, 15)].bg, BACKGROUND); // background separates sidebar
        assert!(text.contains("▄▄▄▄▄▄"), "Mash logo art in the sidebar");
        assert_eq!(buffer[(form.x, form.y)].bg, BACKGROUND);
        assert!(!text.contains('│'));
    }

    #[test]
    fn preview_shows_its_navigation_instead_of_form_shortcuts() {
        let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
        terminal
            .draw(|frame| {
                page_area(frame, Some(0));
                preview_hint(frame);
            })
            .unwrap();
        let text = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(text.contains("←/→ pages · Esc back"));
        assert!(!text.contains("Tab to move"));
    }

    #[test]
    fn installation_keeps_the_completed_page_index() {
        let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
        terminal
            .draw(|frame| {
                page_area(frame, None);
            })
            .unwrap();
        let text = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(text.contains("✓ 06 Appearance"));
        assert!(text.contains("✓ 07 Dictation"));
        assert!(text.contains("Installing…"));
    }

    #[test]
    fn narrow_terminal_preserves_full_width_for_the_form() {
        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        let mut form = Rect::default();
        terminal
            .draw(|frame| form = page_area(frame, Some(0)))
            .unwrap();
        let text = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(text.contains("Setup 1/7"));
        assert!(!text.contains("Providers"));
        assert_eq!(form.x, 0);
        assert_eq!(form.width, 80);
        assert_eq!(terminal.backend().buffer()[(0, 0)].bg, SURFACE);
        assert_eq!(terminal.backend().buffer()[(0, 2)].bg, BACKGROUND);
    }
}
