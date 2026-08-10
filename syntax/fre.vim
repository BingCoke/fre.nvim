if exists('b:current_syntax')
  finish
endif

syntax match FreStableMarker /^\%x1ffre:\d\+:.\{-}:\%(\d\+\|D\+\)\%x1f/ conceal
let b:current_syntax = 'fre'
