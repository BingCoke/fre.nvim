if exists('b:current_syntax')
  finish
endif

syntax match FreStableMarker /^\%x1ffre:\d\{3,}:\d\{3,}\%x1f/ conceal
let b:current_syntax = 'fre'
