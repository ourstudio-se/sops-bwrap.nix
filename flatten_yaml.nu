#!/usr/bin/env -S nu --stdin

def prefix [path: string, sep: string] {
    if ($in | is-empty) { $path } else { $in | append $path | str join $sep }
}

def flatten_yaml_at [prefix: string, sep: string] {
    let data = $in 
    let type = $data | describe -d | get type  

    if $type == "record" {
        $data | items {|key, value|
            let new_prefix = $prefix | prefix $key $sep
            $value | flatten_yaml_at $new_prefix $sep
        } | flatten 
    } else if $type == "list" {
        $data | enumerate | each {|item|
            let new_prefix = $prefix | prefix ($item.index | into string) $sep
            $item.item | flatten_yaml_at $new_prefix $sep
        } | flatten
    } else {
        {key: $prefix, value: $data}
    }
}

def main [sep: string = "__"] {
    $in | from yaml | flatten_yaml_at "" $sep | reduce --fold {} {|it, acc|
        $acc | insert $it.key {$it.value}
    } | to toml
}
