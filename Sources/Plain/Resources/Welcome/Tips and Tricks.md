# Tips and Tricks

## Moving around

| Do this | Press |
|---|---|
| Open a file in this folder | ⌘P |
| Go to a heading | ⌘R |
| Run any command by name | ⇧⌘P |
| Switch between recent tabs | ⌃Tab, keep ⌃ held |
| Go to tab 1 to 9 | ⌘1 … ⌘9 |
| Back to the last place you typed | ⇧⌘⌫ |
| Find in this file | ⌘F, then ⌘G for the next match |
| Find across the folder | ⇧⌘F |

## Writing

- Lists continue when you press Return. Return on an empty item ends the list.
- Tab and ⇧Tab indent and outdent list items and table cells.
- ⌘B, ⌘I and ⌘K wrap the selection in bold, italic or a link. Press them again to unwrap.
- ⌘D adds the next match of the selected word as another selection; type to change them all.
- ⌥-click puts another caret where you click.
- ⌥↑ grows the selection to the word, sentence, line, paragraph and section; ⌥↓ shrinks it back.
- Type `:` and a few letters for emoji, or start a link path to see matching files.
- Paste an image and Plain saves it in a `.pastes` folder and links to it.

## Seeing more, or less

- ⇧⌘I shows the preview beside the text; **View › Preview** shows only the preview.
- ⌘. hides the tabs, sidebar and counters. Press it again to bring them back.
- ⌥⌘T keeps the line you are typing in the middle of the window.
- ⌥⌘L switches to the dark look.

## Settings

**Plain › Preferences…** opens a Markdown file with your settings in it. Change a value and save; Plain applies it at once. **Plain › Keyboard Shortcuts…** works the same way for every shortcut.

## From the Terminal

Link the `plain` command once:

```bash
ln -s /Applications/Plain.app/Contents/Resources/bin/plain /usr/local/bin/plain
```

Then `plain notes.md` opens the file in Plain.
