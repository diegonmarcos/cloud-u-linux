# Shapes 2_configs/*.json into the window.MYDATA object the shell reads.
# Kept as a file, not an inline shell string: the jq program contains $, quotes
# and // operators that get eaten by nested heredoc/quoting in build.sh.
{
  bookmarks:     ($mybar[0].bookmarks    // []),
  pinned:        ($mybar[0].pinned       // []),
  plugins:       ($plugins[0].plugins    // []),
  keybindings:   ($keys[0]               // {}),
  settings:      ($settings[0]           // {}),
  searchEngines: ($engines[0]            // {})
}
