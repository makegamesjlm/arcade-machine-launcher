# MakeGamesJLM Arcade — Idle Screen (MVP) Animation Brief

## Objective

Design a clean, welcoming idle (attract mode) screen for the MakeGamesJLM Arcade that plays whenever the machine is inactive.

The screen has four goals

1. Explain what the arcade is.
2. Show that the games were made by the local game development community.
3. Invite people to join the community.
4. Encourage people to immediately start playing.

This is intentionally an MVP. Prioritize clarity and readability over elaborate animation.

---

# Technical

- Loop length 15–20 seconds
- Silent (no audio)
- Native arcade monitor resolution
- Continuous seamless loop
- **Must be encoded as Ogg Theora (`.ogv`)** — Godot 4's VideoStreamPlayer
  decodes nothing else. Deliver the finished file to
  `~/Nextcloud/Arcade/attract.ogv` on the cabinet (path overridable with
  `--attract-video=` / `ARCADE_ATTRACT_VIDEO`); a missing or wrong-format file
  falls back to a built-in static screen rather than showing black.

---

# Visual Style

The screen should feel

- Modern indie arcade
- Friendly and approachable
- Clean rather than busy
- Slightly playful
- Consistent with the MakeGamesJLM visual identity

## Motion

Use only subtle ambient animation.

Examples

- Floating pixel particles
- Tiny background movement
- Gentle decorative motion
- Soft looping background elements

Do not animate the text.

Text should remain perfectly stable for readability.

---

# Layout

Everything should fit on a single screen.

The screen should be visually divided into three sections.

---

# Logos

Display throughout the screen.

- MakeGamesJLM logo
- Hamiffal logo

Place one in each upper corner.

Keep them relatively small so they support the design rather than dominate it.

---

# Content

## Section 1 — Title

### English

MakeGamesJLM Arcade

Play Jerusalem Games

### Hebrew

שחקו במשחקים ירושלמיים

### Arabic

العبوا ألعابًا صُنعت في القدس

---

## Section 2 — Community

### English

Made by MakeGamesJLM

We make games in Jerusalem.

### Hebrew

נוצר על ידי MakeGamesJLM

אנחנו יוצרים משחקים בירושלים.

### Arabic

صُنع بواسطة MakeGamesJLM

نحن نصنع الألعاب في القدس.

Display a prominent QR code alongside this section.

The QR should link to

https://makegamesjlm.com

(Website functions as the community link hub.)

---

## Section 3 — Invitation

### English

Come join us every Tuesday!

1830–2200

Hamiffal

### Hebrew

הצטרפו אלינו בכל יום שלישי!

1830–2200

המפעל

### Arabic

انضموا إلينا كل يوم ثلاثاء!

1830–2200

هميفعال

---

# Bottom Bar

Persistent across the entire screen.

Use a contrasting horizontal bar along the bottom.

Centered text

## English

PRESS ANY BUTTON TO BEGIN

## Hebrew

לחצו על כל כפתור כדי להתחיל

## Arabic

اضغط أي زر للبدء

A very subtle breathing effect on the bottom bar is acceptable, but the text itself should remain readable and stable.

---

# Typography

- English should be the primary language visually.
- Hebrew and Arabic should be slightly smaller but still comfortably readable.
- Group translations together so they are easy to scan.
- Use generous spacing between sections.

---

# QR Code

Requirements

- Large enough to scan comfortably from standing distance.
- Maintain sufficient whitespace around it.
- Place adjacent to the Made by MakeGamesJLM section.

---

# Design Notes

- Readability is more important than decoration.
- The entire purpose should be understandable within 2–3 seconds.
- The screen should feel like part of the arcade, not a corporate advertisement.
- Avoid clutter.
- Use subtle arcade-inspired visual elements, but let the typography do most of the communication.