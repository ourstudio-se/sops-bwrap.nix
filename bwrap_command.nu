let FLAG_TYPE_NONE = 0x00
let FLAG_TYPE_STRIP = 0x01
let FLAG_TYPE_ALLOW = 0x02

def subst_tpl [control_char: string; replace_val: string; padding_before: bool] {
    str replace $control_char (if $replace_val != "" { if $padding_before { " " + $replace_val } else { $replace_val + " " } } else "")
}

def filter_vars [list: list<string>] {
    let vars = $in
    if ($list | length) > 0 {
        $vars | columns | reduce --fold $vars {|col, acc|
            let matches = $list | any {|pattern|
                $col =~ $pattern
            }
            if $matches {
                $acc
            } else {
                $acc | reject $col
            }
        }
    } else {
        $vars
    }
}

def strip_vars [list: list<string>] {
    let src = $in
    $src | columns | reduce --fold {} {|col, acc|
        let col_stripped = $list | reduce --fold $col {|pattern, inner_acc|
            $inner_acc | str replace -r $pattern ""
        }
        $acc | upsert $col_stripped ($src | get $col)
    }
}

def consume_rest_args [rest_args: list<string>] {
    $rest_args | reduce --fold { last_flag: FLAG_TYPE_NONE allowlist: [] striplist: [] } {|arg, acc|
        if $arg == "--allow-key" {
            $acc | upsert last_flag $FLAG_TYPE_ALLOW
        } else if $arg == "--strip" {
            $acc | upsert last_flag $FLAG_TYPE_STRIP
        } else if $acc.last_flag == $FLAG_TYPE_ALLOW {
            $acc | upsert last_flag $FLAG_TYPE_NONE | upsert allowlist ($acc.allowlist | append $arg)
        } else if $acc.last_flag == $FLAG_TYPE_STRIP {
            $acc | upsert last_flag $FLAG_TYPE_NONE | upsert striplist ($acc.striplist | append $arg)
        } else {
            error make { msg: $"Unknown argument passed to bwrap_command: ($arg)" }
        }
    } | select allowlist striplist
}

def --wrapped main [--cmd: string, --control-char: string = "\u{FE00}", --redact = false, --template: string, --arg-template: string = "'%k=%v'", ...argv: string] {
    let consumed_rest_args = consume_rest_args $argv
    let allowlist = $consumed_rest_args.allowlist
    let striplist = $consumed_rest_args.striplist

    let vars = $in | from toml | filter_vars $striplist | strip_vars $striplist | filter_vars $allowlist

    let arg_str = $vars | items {|key, value|
        $arg_template | str replace '%k' $key | str replace '%v' (if $redact { "***" } else { $value }) | str trim --char "'"
    } | str join " " 

    let cmd_length = $cmd | str length
    let cmd_begin = $cmd | str index-of -g ($control_char)
    let cmd_end = $cmd | str index-of -g -e ($control_char)

    let cmd_ingress = if $cmd_begin > 0 {
        $cmd | str substring -g 0..($cmd_begin - 1)
    } else ""

    let cmd_egress = if $cmd_end != -1 and $cmd_end < $cmd_length - 1 {
        $cmd | str substring -g ($cmd_end + 1)..
    } else ""

    let cmd_body = if $cmd_begin == -1 and $cmd_end == -1 { $cmd } else {
        $cmd | str substring -g (if $cmd_begin != -1 {$cmd_begin} else 0)..(if $cmd_end != -1 {$cmd_end} else $cmd_length)
    }

    $template 
        | str replace '%v' (if ($arg_str | str length) > 0 {
            " " + $arg_str
        } else {
            ""
        })
        | str replace '%V' (if ($arg_str | str length) > 0 {
            $arg_str + " "
        } else {
            ""
        })
        | subst_tpl '%a' $cmd_ingress true
        | subst_tpl '%A' $cmd_ingress false
        | subst_tpl '%z' $cmd_egress true
        | subst_tpl '%Z' $cmd_egress false
        | str replace '%c' $cmd_body
}
