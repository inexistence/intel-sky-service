# Reverse-engineering helpers

`swift-field-metadata.mjs` reads Swift field descriptors directly from a 64-bit little-endian
Mach-O `__swift5_fieldmd` section. It avoids loading or executing the reference runtime and does
not require its architecture to match the host.

```sh
node Tools/reverse/swift-field-metadata.mjs /path/to/SkyComputerUseService RefetchableSkyshotAXTree
```

The optional query matches both type names and field/case names. Mangled field types may contain
Swift symbolic-reference bytes; field and enum-case names remain directly readable.
