---
title: Markdown Support
tags: [reference, plain]
---

# Markdown Support

Front matter at the very top of a file, between two `---` lines, is shown as code and left out of the preview.

[[toc]]

## Headings

Six levels start with `#` to `######`:

### Third level

#### Fourth level

##### Fifth level

###### Sixth level

A Second Style Of Heading
-------------------------

## Text

Plain text, *emphasis*, **strong**, ~~struck out~~ and ::marked:: text. `Inline code` keeps its spaces.
A line that ends with two spaces  
breaks without starting a new paragraph. Escape a mark with a backslash: \*not italic\*.

Emoji by name :smile: :tada:, and HTML tags such as <kbd>⌘</kbd>+<kbd>S</kbd> pass through. Template tags like {{ page.title }} stay as written.

## Links and images

- An inline [link to Plain's welcome](Welcome.md) and an [external link](https://www.markdownguide.org).
- A [reference link][guide] and a shortcut reference like [guide].
- Autolinks: <https://commonmark.org>, and a bare address such as https://github.com or hello@example.com.
- Footnotes look like this.[^first]
- An image: ![Plain logo](Images/plain-logo.png)
- A reference image: ![Logo again][logo]

[guide]: https://www.markdownguide.org/basic-syntax/
[logo]: Images/plain-logo.png

[^first]: The note text sits at the bottom of the preview, with a link back.

## Lists

- A bullet item
  - A nested item
- Another item

1. First
2. Second
3. Third

- [x] A finished task
- [ ] A task still to do

## Quotes

> A quote can hold *any* Markdown.
>
> - even lists

## Code

```swift
let greeting = "Hello"
print(greeting)
```

    Four spaces of indent also make a code block.

## Tables

| Left | Centre | Right |
|:-----|:------:|------:|
| a    |   b    |     c |
| one  |  two   | three |

## Maths

Inline maths $E = mc^2$ sits in the line, and $$\sum_{i=1}^{n} i$$ shows in display style.

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

## HTML

<details>
<summary>Raw HTML blocks show in the preview</summary>

Inside them, Markdown still works.

</details>

<!-- An HTML comment never shows in the preview. -->

## Attributes

A heading with attributes {#custom-id .note}

## Breaks

A thematic break draws a line:

---

A page break starts a new page when you export to PDF:

+++

The end.
