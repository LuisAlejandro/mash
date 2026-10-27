//! Entry screen shown only before the first-launch configuration flow.
use crate::wizard_style;
use ratatui::{
    crossterm::event::{Event, KeyCode, KeyEventKind, MouseButton, MouseEventKind},
    layout::Rect,
    style::{Color, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
    Frame,
};

// One source of truth: Pi's header and the wizard use the same Mash art.
const ART: &str = include_str!("../defaults/pi/extensions/header-art.ansi");
const BUTTON_WIDTH: u16 = 23;

// The bundled logo uses only SGR resets and 24-bit foreground/background
// colors. Interpret those in Ratatui rather than printing escape bytes into
// its cell buffer (which would show garbage and break mouse coordinates).
pub fn art_lines() -> Vec<Line<'static>> {
    ART.lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let mut rest = line;
            let mut spans = Vec::new();
            let mut style = Style::default()
                .fg(wizard_style::TEXT)
                .bg(wizard_style::PANEL);
            while let Some(start) = rest.find("\x1b[") {
                if start > 0 {
                    spans.push(Span::styled(rest[..start].to_owned(), style));
                }
                let escape = &rest[start + 2..];
                let Some((codes, tail)) = escape.split_once('m') else {
                    rest = &rest[start..];
                    break;
                };
                let codes: Vec<u8> = codes
                    .split(';')
                    .filter_map(|code| code.parse().ok())
                    .collect();
                let mut index = 0;
                while index < codes.len() {
                    match codes[index] {
                        0 => {
                            style = Style::default()
                                .fg(wizard_style::TEXT)
                                .bg(wizard_style::PANEL)
                        }
                        38 | 48 if index + 4 < codes.len() && codes[index + 1] == 2 => {
                            let rgb =
                                Color::Rgb(codes[index + 2], codes[index + 3], codes[index + 4]);
                            style = if codes[index] == 38 {
                                style.fg(rgb)
                            } else {
                                style.bg(rgb)
                            };
                            index += 4;
                        }
                        _ => {}
                    }
                    index += 1;
                }
                rest = tail;
            }
            if !rest.is_empty() {
                spans.push(Span::styled(rest.to_owned(), style));
            }
            Line::from(spans)
        })
        .collect()
}

/// Render the logo and button. Return the clickable button rectangle.
pub fn draw(frame: &mut Frame) -> Rect {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(
            Style::default()
                .fg(wizard_style::TEXT)
                .bg(wizard_style::PANEL),
        ),
        area,
    );
    let art = art_lines();
    let art_width = art.iter().map(Line::width).max().unwrap_or(0) as u16;
    let compact = area.width < art_width.saturating_add(4)
        || area.height < (art.len() as u16).saturating_add(7);
    let logo_height = if compact { 1 } else { art.len() as u16 };
    let gap = if area.height >= logo_height + 5 { 2 } else { 0 };
    let button_height = 1.min(area.height.saturating_sub(logo_height + gap));
    let top = area.y
        + area
            .height
            .saturating_sub(logo_height + gap + button_height)
            / 2;
    let logo_width = if compact { 4 } else { art_width }.min(area.width);
    let logo = Rect::new(
        area.x + area.width.saturating_sub(logo_width) / 2,
        top,
        logo_width,
        logo_height,
    );
    if compact {
        frame.render_widget(
            Paragraph::new("MASH").style(Style::default().fg(wizard_style::YELLOW)),
            logo,
        );
    } else {
        frame.render_widget(Paragraph::new(art), logo);
    }

    let button_width = BUTTON_WIDTH.min(area.width);
    let button = Rect::new(
        area.x + area.width.saturating_sub(button_width) / 2,
        top + logo_height + gap,
        button_width,
        button_height,
    );
    frame.render_widget(
        Paragraph::new(" Start config wizard ")
            .alignment(ratatui::layout::Alignment::Center)
            .style(wizard_style::selected()),
        button,
    );
    button
}

/// One focused button: click its bounds or press Enter/Space. Other mouse
/// events never begin setup.
pub fn starts_on(event: &Event, button: Rect) -> bool {
    match event {
        Event::Key(key) => {
            key.kind == KeyEventKind::Press
                && matches!(key.code, KeyCode::Enter | KeyCode::Char(' '))
        }
        Event::Mouse(mouse) => {
            mouse.kind == MouseEventKind::Down(MouseButton::Left)
                && mouse.column >= button.x
                && mouse.column < button.right()
                && mouse.row >= button.y
                && mouse.row < button.bottom()
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{
        backend::TestBackend,
        crossterm::event::{KeyEvent, KeyModifiers, MouseEvent},
        Terminal,
    };

    #[test]
    fn full_logo_and_start_button_are_centered_without_escape_bytes() {
        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        let mut button = Rect::default();
        terminal.draw(|frame| button = draw(frame)).unwrap();
        let buffer = terminal.backend().buffer();
        let text = buffer
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(text.contains("▄▄▄▄▄▄"));
        assert!(text.contains("Start config wizard"));
        assert!(!text.contains('\x1b'));
        assert_eq!(button.width, BUTTON_WIDTH);
        assert_eq!(button.height, 1);
        assert_eq!(button.x, (80 - BUTTON_WIDTH) / 2);
        assert_eq!(
            buffer[(button.x, button.y)].bg,
            wizard_style::selected().bg.unwrap()
        );
        assert_eq!(buffer[(button.x, button.y)].symbol(), " ");
        assert!(!text.contains('┌'));
        assert_eq!(
            art_lines()[0].spans[0].style.fg,
            Some(Color::Rgb(255, 85, 85))
        );
    }

    #[test]
    fn small_terminal_keeps_the_button_visible() {
        let mut terminal = Terminal::new(TestBackend::new(30, 10)).unwrap();
        let mut button = Rect::default();
        terminal.draw(|frame| button = draw(frame)).unwrap();
        let text = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(text.contains("MASH"));
        assert!(text.contains("Start config wizard"));
        assert_eq!(button.height, 1);
        assert!(button.y + button.height <= 10);
    }

    #[test]
    fn only_clicks_on_the_button_or_keyboard_activation_start_setup() {
        let button = Rect::new(10, 12, BUTTON_WIDTH, 1);
        let mouse = |column, row, kind| {
            Event::Mouse(MouseEvent {
                kind,
                column,
                row,
                modifiers: KeyModifiers::NONE,
            })
        };
        assert!(starts_on(
            &Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
            button
        ));
        assert!(starts_on(
            &Event::Key(KeyEvent::new(KeyCode::Char(' '), KeyModifiers::NONE)),
            button
        ));
        assert!(starts_on(
            &mouse(20, 12, MouseEventKind::Down(MouseButton::Left)),
            button
        ));
        assert!(!starts_on(
            &mouse(33, 12, MouseEventKind::Down(MouseButton::Left)),
            button
        ));
        assert!(!starts_on(
            &mouse(20, 11, MouseEventKind::Down(MouseButton::Left)),
            button
        ));
        assert!(!starts_on(
            &mouse(20, 12, MouseEventKind::Down(MouseButton::Right)),
            button
        ));
    }
}
