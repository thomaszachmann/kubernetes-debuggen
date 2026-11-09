// Layout und Bausteine für das Handbuch.

#let tinte = rgb("#1f2a33")
#let grau = rgb("#5d6b76")
#let linie = rgb("#d8dcd9")
#let papier = rgb("#faf8f3")
#let akzent = rgb("#8e2f63")
#let akzent-hell = rgb("#f6e9f0")
#let warn = rgb("#a4521d")
#let warn-hell = rgb("#fbeee2")
#let code-bg = rgb("#f3f4f1")
#let probe = rgb("#2f6a3f")
#let probe-hell = rgb("#e8f2e9")
#let lila = rgb("#59478a")
#let lila-hell = rgb("#eeebf6")

#let serif = ("Charter", "Palatino")
#let sans = ("Avenir Next", "Helvetica Neue")
#let mono = ("Menlo", "DejaVu Sans Mono")

// Stand der Vorlage: gemeinsamer Zähler für Befehle pro Kapitel
#let befehl-nr = counter("befehl")

#let etikett(farbe, text-inhalt) = box(
  fill: farbe, radius: 2pt, inset: (x: 5pt, y: 2.5pt),
  text(font: sans, size: 7pt, weight: "semibold", fill: white, tracking: 0.4pt, upper(text-inhalt)),
)

// Ein einzelner Befehl mit Ort (Mac, Pod oder Name der VM) und Erklärung darunter.
#let cmd(ort, code, erklaerung) = {
  befehl-nr.step()
  let farbe = if ort == "Mac" { akzent } else if ort == "Pod" { lila } else if ort == "k9s" { probe } else { warn }
  block(breakable: false, width: 100%, above: 1.1em, below: 0.35em)[
    #block(
      width: 100%, fill: code-bg, radius: (top: 3pt, bottom: 3pt),
      stroke: (left: 2.2pt + farbe), inset: (left: 10pt, right: 8pt, top: 7pt, bottom: 8pt),
      below: 0pt,
    )[
      #grid(columns: (1fr, auto), align: horizon, row-gutter: 0pt,
        etikett(farbe, ort),
        text(font: sans, size: 7pt, fill: grau)[Step #context befehl-nr.display()],
      )
      #v(-3pt)
      #set text(font: mono, size: 8.1pt, fill: tinte)
      #code
    ]
  ]
  block(above: 0.45em, below: 1em, inset: (left: 12.2pt))[
    #set text(size: 9.6pt)
    #erklaerung
  ]
}

// Eine Datei, die angelegt wird.
#let datei(pfad, code, erklaerung: none) = {
  block(width: 100%, breakable: true, above: 1.1em, below: 0.4em)[
    #block(
      width: 100%, fill: rgb("#e9ebe6"), radius: (top: 3pt),
      inset: (x: 10pt, y: 5pt), below: 0pt, sticky: true,
    )[
      #text(font: sans, size: 7.5pt, weight: "semibold", fill: grau)[FILE]
      #h(6pt)
      #text(font: mono, size: 8pt, fill: tinte)[#pfad]
    ]
    #block(
      width: 100%, fill: code-bg, radius: (bottom: 3pt),
      inset: (x: 10pt, y: 8pt), breakable: true,
    )[
      #set text(font: mono, size: 8pt, fill: tinte)
      #code
    ]
  ]
  if erklaerung != none {
    block(above: 0.45em, below: 1em, inset: (left: 2pt))[
      #set text(size: 9.6pt)
      #erklaerung
    ]
  }
}

#let hinweis(titel, farbe, hell, inhalt) = block(
  width: 100%, fill: hell, radius: 3pt, inset: 10pt,
  above: 1.1em, below: 1.1em, breakable: false,
)[
  #text(font: sans, size: 8pt, weight: "bold", fill: farbe, tracking: 0.4pt)[#upper(titel)]
  #v(-0.25em)
  #set text(size: 9.5pt)
  #inhalt
]

#let warum(inhalt) = hinweis("Why it matters", akzent, akzent-hell, inhalt)
#let falle(inhalt) = hinweis("Pitfall", warn, warn-hell, inhalt)
#let pruefe(inhalt) = hinweis("What you should see", probe, probe-hell, inhalt)
#let aufgabe(inhalt) = hinweis("Try it yourself", lila, lila-hell, inhalt)

#let gelernt(..punkte) = block(
  width: 100%, stroke: (top: 1pt + linie, bottom: 1pt + linie),
  inset: (y: 10pt), above: 1.6em, below: 1em, breakable: false,
)[
  #text(font: sans, size: 8pt, weight: "bold", fill: tinte, tracking: 0.4pt)[WHAT YOU LEARNED]
  #v(-0.2em)
  #set text(size: 9.6pt)
  #for p in punkte.pos() [
    - #p
  ]
]

// Kapitelanfang mit Ziel, Zeit und Voraussetzung.
#let kapitel(titel, ziel: none, zeit: none, braucht: none) = {
  pagebreak(weak: true, to: "odd")
  befehl-nr.update(0)
  heading(level: 1, titel)
  if ziel != none {
    block(above: 0.4em, below: 1.5em)[
      #set text(size: 11pt, fill: grau, style: "italic")
      #ziel
    ]
  }
  if zeit != none or braucht != none {
    block(
      width: 100%, stroke: (top: 0.6pt + linie, bottom: 0.6pt + linie),
      inset: (y: 7pt), below: 1.6em,
    )[
      #set text(font: sans, size: 8.5pt, fill: grau)
      #if zeit != none [*Time:* #zeit]
      #if zeit != none and braucht != none [#h(1.4em)]
      #if braucht != none [*Requires:* #braucht]
    ]
  }
}

#let tabelle(spalten, kopf, ..zeilen) = {
  set text(size: 9pt)
  block(above: 1em, below: 1.1em, breakable: true)[
    #table(
      columns: spalten,
      stroke: (x, y) => (bottom: 0.5pt + linie, top: if y == 0 { 1pt + tinte } else { 0pt }),
      inset: (x: 5pt, y: 5.5pt),
      table.header(..kopf.map(k => text(font: sans, size: 8.2pt, weight: "semibold", fill: tinte)[#k])),
      ..zeilen.pos(),
    )
  ]
}

// Cover: hell, ruhig, konzentrische Schutzschichten als Motiv.
#let cover(titel, untertitel, autor, stand) = {
  set page(width: 19cm, height: 25cm, fill: papier, margin: 0pt, header: none, footer: none, numbering: none)
  let breite = 19cm
  let mitte-x = 12.6cm
  let mitte-y = 16.9cm
  let ringe = (
    (6.9cm, color.mix((akzent, 6%), (papier, 94%))),
    (5.7cm, color.mix((akzent, 11%), (papier, 89%))),
    (4.5cm, color.mix((akzent, 20%), (papier, 80%))),
    (3.2cm, color.mix((akzent, 38%), (papier, 62%))),
    (2.0cm, color.mix((akzent, 68%), (papier, 32%))),
    (0.9cm, akzent),
  )
  block(width: 100%, height: 100%, clip: true)[
    #for (r, farbe) in ringe {
      place(top + left, dx: mitte-x - r, dy: mitte-y - r, circle(radius: r, fill: farbe))
    }
    #place(top + left, dx: 2.1cm, dy: 2.3cm)[
      #block(width: 13cm)[
        #text(font: sans, size: 9.5pt, weight: "semibold", fill: akzent, tracking: 1.3pt)[HANDS-ON GUIDE]
        #v(0.75cm)
        #set par(leading: 0.42em, justify: false)
        #text(font: serif, size: 40pt, fill: tinte, weight: "regular")[#titel]
        #v(0.5cm)
        #set par(leading: 0.6em)
        #text(font: sans, size: 13pt, fill: grau)[#untertitel]
      ]
    ]
    #place(bottom + left, dx: 2.1cm, dy: -2.1cm)[
      #set par(leading: 0.6em, justify: false)
      #text(font: sans, size: 10.5pt, weight: "semibold", fill: tinte)[#autor] \
      #text(font: sans, size: 9pt, fill: grau)[#stand]
    ]
  ]
}

// Rückseite: greift die Ringe der Vorderseite auf, angeschnitten unten links.
#let rueckseite(titel, klappentext, inhalt, fusszeile, autor: none, autor-bild: none, autor-text: none) = {
  set page(width: 19cm, height: 25cm, fill: papier, margin: 0pt, header: none, footer: none, numbering: none)
  let mitte-x = 2.4cm
  let mitte-y = 22.6cm
  let ringe = (
    (4.6cm, color.mix((akzent, 6%), (papier, 94%))),
    (3.6cm, color.mix((akzent, 11%), (papier, 89%))),
    (2.6cm, color.mix((akzent, 20%), (papier, 80%))),
    (1.6cm, color.mix((akzent, 38%), (papier, 62%))),
    (0.7cm, akzent),
  )
  block(width: 100%, height: 100%, clip: true)[
    #for (r, farbe) in ringe {
      place(top + left, dx: mitte-x - r, dy: mitte-y - r, circle(radius: r, fill: farbe))
    }
    #place(top + left, dx: 2.1cm, dy: 2.4cm)[
      #block(width: 14.8cm)[
        #set par(justify: false)
        #text(font: sans, size: 9.5pt, weight: "semibold", fill: akzent, tracking: 1.3pt)[#upper(titel)]
        #v(0.6cm)
        #set par(leading: 0.62em, spacing: 0.9em)
        #text(font: serif, size: 15pt, fill: tinte)[#klappentext]
        #v(0.9cm)
        #text(font: sans, size: 8.5pt, weight: "semibold", fill: grau, tracking: 1.1pt)[INSIDE]
        #v(0.3cm)
        #set text(font: sans, size: 10pt, fill: tinte)
        #grid(
          columns: (auto, 1fr),
          column-gutter: 0.55cm,
          row-gutter: 0.42cm,
          ..inhalt.map(((k, t)) => (
            text(fill: akzent, weight: "semibold")[#k], t,
          )).flatten(),
        )
      ]
    ]
    #if autor-bild != none {
      place(bottom + right, dx: -2.1cm, dy: -3.3cm, block(width: 10.5cm)[
        #set par(justify: false, leading: 0.55em)
        #grid(
          columns: (1fr, 2.6cm),
          column-gutter: 0.5cm,
          align: (right + horizon, horizon),
          [
            #text(font: sans, size: 10.5pt, weight: "semibold", fill: tinte)[#autor] \
            #text(font: sans, size: 9pt, fill: grau)[#autor-text]
          ],
          box(
            width: 2.6cm, height: 2.6cm, radius: 1.3cm, clip: true,
            stroke: 2pt + white,
            image(autor-bild, width: 100%, height: 100%, fit: "cover"),
          ),
        )
      ])
    }
    #place(bottom + right, dx: -2.1cm, dy: -2.1cm)[
      #set par(justify: false)
      #align(right, text(font: sans, size: 8.5pt, fill: grau)[#fusszeile])
    ]
  ]
}

#let titel-dokument = "Debugging Kubernetes"

#let buch(body) = {
  set document(title: titel-dokument, author: "Thomas Zachmann")
  set text(font: serif, size: 10.2pt, fill: tinte, lang: "en", region: "US", hyphenate: true)
  set par(justify: true, leading: 0.72em, spacing: 1em)
  show raw.where(block: false): it => box(
    fill: code-bg, radius: 2pt, inset: (x: 2.5pt), outset: (y: 2pt),
    text(font: mono, size: 0.82em, it.text),
  )
  show raw.where(block: true): set par(justify: false, leading: 0.62em)
  show link: it => text(fill: akzent, it)
  set list(indent: 0.6em, body-indent: 0.5em, marker: text(fill: akzent)[•])
  set enum(indent: 0.6em)

  set heading(numbering: "1.1")
  show heading.where(level: 1): it => {
    set par(justify: false, leading: 0.5em)
    block(above: 0pt, below: 0.9em)[
      #if it.numbering != none [
        #text(font: sans, size: 9.5pt, weight: "semibold", fill: akzent, tracking: 1.1pt)[CHAPTER #counter(heading).display("1")]
        #v(0.12cm)
      ]
      #text(font: serif, size: 25pt, weight: "regular", fill: tinte)[#it.body]
    ]
  }
  show heading.where(level: 2): it => block(above: 1.7em, below: 0.75em, sticky: true)[
    #set par(justify: false)
    #text(font: sans, size: 12.5pt, weight: "semibold", fill: tinte)[
      #if it.numbering != none [#text(fill: akzent)[#counter(heading).display()] #h(0.35em)]#it.body
    ]
  ]
  show heading.where(level: 3): it => block(above: 1.3em, below: 0.6em, sticky: true)[
    #set par(justify: false)
    #text(font: sans, size: 10.2pt, weight: "semibold", fill: tinte)[#it.body]
  ]

  set page(
    width: 19cm, height: 25cm,
    margin: (inside: 2.1cm, outside: 1.9cm, top: 2.2cm, bottom: 2.2cm),
    header: context {
      let seite = here().page()
      let spaeter = query(heading.where(level: 1).after(here()))
      if spaeter.len() > 0 and spaeter.first().location().page() == seite { return }
      let frueher = query(heading.where(level: 1).before(here()))
      if frueher.len() == 0 { return }
      set text(font: sans, size: 7.8pt, fill: grau)
      if calc.even(seite) { frueher.last().body } else { align(right, frueher.last().body) }
    },
    footer: context {
      set text(font: sans, size: 8pt, fill: grau)
      let n = counter(page).display()
      if calc.even(here().page()) { n } else { align(right, n) }
    },
  )
  body
}

// Bausteine für Fehlerszenarien
#let rot = rgb("#a3283c")
#let rot-hell = rgb("#f8e6e9")
#let symptom(inhalt) = hinweis("Symptom", rot, rot-hell, inhalt)
#let ursache(inhalt) = hinweis("Cause", akzent, akzent-hell, inhalt)

// Unterschied zwischen den beiden Distributionen, als zweispaltiger Kasten
#let distro(rke2, talos) = block(
  width: 100%, above: 1.1em, below: 1.1em, breakable: false,
  stroke: 0.6pt + linie, radius: 3pt, inset: 0pt,
)[
  #grid(
    columns: (1fr, 1fr),
    inset: 9pt,
    stroke: (x, y) => if x == 1 { (left: 0.6pt + linie) },
    [
      #text(font: sans, size: 8pt, weight: "bold", fill: warn, tracking: 0.4pt)[RKE2]
      #v(-0.25em)
      #set text(size: 9.2pt)
      #rke2
    ],
    [
      #text(font: sans, size: 8pt, weight: "bold", fill: warn, tracking: 0.4pt)[TALOS]
      #v(-0.25em)
      #set text(size: 9.2pt)
      #talos
    ],
  )
]
