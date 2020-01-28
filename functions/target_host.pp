function pe_xl::target_host(
  Variant[Target, Array[Target,0,1]] $target,
) >> Variant[String, Undef] {
  case $target {
    Target: {
      $target.name
    }
    Array[Target,1,1]: {
      $target[0].name
    }
    Array[Target,0,0]: {
      undef
    }
  }
}