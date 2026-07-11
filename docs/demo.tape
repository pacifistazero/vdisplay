# vdisplay CLI demo — render with:  vhs docs/demo.tape
Output docs/demo.gif

Set FontSize 18
Set Width 1100
Set Height 660
Set Padding 20
Set Theme "Dracula"

Hide
Type "export PATH=$HOME/.local/bin:$PATH && clear" Enter
Show

Type "vdisplay --help" Sleep 700ms Enter Sleep 2.5s
Type "vdisplay list" Sleep 700ms Enter Sleep 2s
Type 'vdisplay add "Cinema 21:9" 3440 1440' Sleep 500ms Enter Sleep 1.5s
Type "vdisplay list" Sleep 500ms Enter Sleep 2s
Type "vdisplay layouts" Sleep 500ms Enter Sleep 1.5s
Type "vdisplay startup-layout" Sleep 500ms Enter Sleep 2s

Hide
Type 'vdisplay remove "Cinema 21:9"' Enter
Show
Sleep 1s
