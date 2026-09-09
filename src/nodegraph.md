---
state:
  selected: ""
  positions: ""
---
# `:::nodegraph` — beat 1

Drag a node. Drag empty canvas, or hold the middle button anywhere, to
pan. Wheel to zoom about the cursor. Click a node to select it; click the
ground to clear. Hovering lights a node, or one of its pins.

Nothing here creates a node, makes a link, or deletes anything — that is
a later beat. This one is the transform, the hit test, the layering and
the wires.

:::nodegraph {#chain width=100% height=460 positions=positions selected=selected}
view pan=-24,-16 zoom=1

node id=src    x=0    y=40   label="Source"   tint=#4e7fd0
node id=env    x=0    y=210  label="Envelope" tint=#4e7fd0
node id=gain   x=210  y=20   label="Gain"     tint=#5f8f6a
node id=mix    x=210  y=180  label="Mix"      tint=#5f8f6a
node id=filter x=430  y=60   label="Filter"   tint=#8a6ec0
node id=out    x=650  y=110  label="Out"      tint=#b06a5a

pin node=src    id=v   dir=out label="v"
pin node=env    id=v   dir=out label="v"

pin node=gain   id=in  dir=in  label="in"
pin node=gain   id=amt dir=in  label="amt"
pin node=gain   id=v   dir=out label="v"

pin node=mix    id=a   dir=in  label="a"
pin node=mix    id=b   dir=in  label="b"
pin node=mix    id=v   dir=out label="v"

pin node=filter id=in  dir=in  label="in"
pin node=filter id=cut dir=in  label="cut"
pin node=filter id=q   dir=in  label="q"
pin node=filter id=v   dir=out label="v"

pin node=out    id=l   dir=in  label="l"
pin node=out    id=r   dir=in  label="r"

link from=src.v    to=gain.in
link from=env.v    to=gain.amt
link from=src.v    to=mix.a
link from=env.v    to=mix.b
link from=gain.v   to=filter.in
link from=mix.v    to=filter.cut
link from=filter.v to=out.l
link from=filter.v to=out.r
:::

Selected node: ::value{text=${state.selected} style=code color=#ffc46a}

A drag writes every node's position to `state.positions` — once, on
release — as `pos id=… x=… y=…` records, which is the same record kind
the description above reads. A host can echo them straight back without
losing a label.
