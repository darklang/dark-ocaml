module Autocomplete exposing (..)

import Types exposing (..)

empty : Autocomplete
empty = { defaults = [], current = [], index = -1 }

init : List String -> Autocomplete
init defaults = { defaults = defaults, current = defaults, index = -1 }

reset : Autocomplete -> Autocomplete
reset a = { defaults = a.defaults, current = a.defaults, index = -1 }

selectDown : Autocomplete -> Autocomplete
selectDown a = let max = (List.length a.current) in
               { a | index = (a.index + 1) % max }

selectUp : Autocomplete -> Autocomplete
selectUp a = let max = (List.length a.current) - 1 in
             { a | index = if a.index == 0 then max else a.index - 1
             }

query : Autocomplete -> String -> Autocomplete
query a str =
  { defaults = a.defaults
  , current = List.filter (\s -> String.contains str s) a.defaults
  , index = 0
  }

update : Autocomplete -> AutocompleteMod -> Autocomplete
update a mod =
  case mod of
    Query str -> query a str
    Reset -> reset a
    SelectDown -> selectDown a
    SelectUp -> selectUp a
