# module-files.jq: a GitHub pull request files list made relative to a module root, the one filter
# behaviour-pass.sh, review-run.sh and verify-pass.sh hand mtf-facts. Use with
#   jq -L <this directory> --arg p <prefix with a trailing slash, or empty> 'include "module-files"; module_files($p)'
#
# A path under the module root loses the prefix and a path outside it is left out. A rename across the
# module root changes what the module holds: renamed out of it, the file is removed from the module, a
# removed entry at its old path; renamed or copied into it, an added file. Neither keeps the patch or the
# line counts of the rename. A copy out of the module root leaves the module unchanged and is left out.
# Only a renamed or copied entry with a non-empty previous_filename is a rename or a copy.
def module_files($p):
  def rel: if $p == "" then . elif startswith($p) then .[($p | length):] else null end;
  [.[] | (.filename | rel) as $n
   | ((.status | IN("renamed", "copied")) and ((.previous_filename // "") | type == "string" and . != "")) as $mv
   | (if $mv then .previous_filename | rel else null end) as $o
   | if $n != null and ($mv | not) then del(.previous_filename) | .filename = $n
     elif $n != null and $o != null then .filename = $n | .previous_filename = $o
     elif $n != null then del(.previous_filename, .patch, .additions, .deletions, .changes) | .filename = $n | .status = "added"
     elif $o != null and .status == "renamed" then
       del(.previous_filename, .patch, .additions, .deletions, .changes) | .filename = $o | .status = "removed"
     else empty end];
