# XML LayoutCatalog

Part of the [FileMaker XML reference](../XML.md) · SaXML v2.2 (FileMaker 22) · `Structure/AddAction` branch

The layouts with everything on them — the largest and deepest branch of the export. A `<Layout>` element covers the layout header (context table occurrence, theme and menu-set references, options, grid style, script triggers) and a `<PartsList>` whose `<Part>` elements contain the actual layout objects. Layout objects nest recursively: tab controls, slide controls, popovers and groups carry their children inside panel elements, reaching nesting depth 5 in practice.

## Structure

```xml
<LayoutCatalog membercount="…">
    <Layout id="2" name="Contacts" width="…" isFolder="False" isSeparatorItem="False">
        <UUID …>…</UUID>
        <TableOccurrenceReference id="…" name="Contacts" UUID="…"/>  <!-- context TO -->
        <LayoutThemeReference id="…" name="…" UUID="…" Base="…" Display="…"/>
        <MenuSet><CustomMenuSetReference id="…" name="…" UUID="…"/></MenuSet>
        <Options hidden="False"/>
        <GridStyle>…</GridStyle> <ClientType>…</ClientType>
        <ScriptTriggers membercount="…">
            <ScriptTrigger action="OnRecordLoad" browseMode="True" findMode="…"
                           previewMode="…" scriptParameterFieldName="…" id="…">
                <ScriptReference id="…" name="…" UUID="…">
                    <Calculation>   <!-- optional script parameter -->
                        <DDRREF kind="ChunkList" hash="…">…</DDRREF>
                        <Text><![CDATA[…]]></Text>
                    </Calculation>
                </ScriptReference>
            </ScriptTrigger>
        </ScriptTriggers>
        <PartsList membercount="…">
            <Part type="Body" kind="…" name="…">
                <Definition size="…" absolute="…" Options="…" kind="…" type="…">
                    <FieldReference …/>   <!-- sub-summary break field only -->
                </Definition>
                <ObjectList membercount="…">
                    <LayoutObject id="7" type="Edit Box" kind="…" name="…" hash="…">
                        <UUID>…</UUID>
                        <Bounds top="…" left="…" bottom="…" right="…"/>
                        <Options>…</Options>
                        <Field>…type-specific payload…</Field>
                        <Conditions>                    <!-- two possible children -->
                            <Formatting membercount="…">  <!-- conditional formatting -->
                                <Condition type="0" id="0">   <!-- 0=formula, 1-13=value operator -->
                                    <Calculation><Text><![CDATA[…]]></Text></Calculation>
                                    <Range Start="…" End="…"/> <Options>…</Options>
                                    <LocalCSS>…</LocalCSS>
                                </Condition>
                            </Formatting>
                            <Hide>…hide condition…</Hide>
                        </Conditions>
                        <LocalCSS>…</LocalCSS> <ExtendedAttributes>…</ExtendedAttributes>
                        <!-- container types (TabControl, SlideControl, PopoverButton,
                             Group, Portal) nest child LayoutObjects in their panels -->
                    </LayoutObject>
                </ObjectList>
            </Part>
        </PartsList>
    </Layout>
</LayoutCatalog>
```

## Notes

- 26 layout-object types occur; the type-specific payload sits in a child element named after the type (`<Field>`, `<Text>`, `<Portal>`, `<TabControl>`, `<GroupedButton>`, `<WebViewer>`, …).
- Buttons can either call a script (`<ScriptReference>`) or embed a **single script step** (`Button/action/Step`) — the importer extracts both reference kinds.
- Hide conditions, tooltips and placeholders are calculations inside the object payload; their `DDRREF` hashes join to [XML DDR_INFO](XML%20DDR_INFO.md). Conditional formatting is the structured `<Conditions><Formatting>` block shown above — one `<Condition>` per rule (`@type` `0` = formula, `1`–`13` = value operator with `<Range>` operands; the `<Options>` bitmask carries the enable bit, `<LocalCSS>` the applied format) — extracted rule-exact into [LayoutObjectConditions](../../schema/catalog-tables/LayoutObjectConditions.md).
- The `<Data>` runs of a text object carry the **merge family**: merge fields (`<<::field>>`), merge variables (`<<$$var>>`), layout calculations (`<<ƒ:%X:formula>>` — the `%X:` prefix declares the result type) and text symbols (`{{CurrentDate}}`, …). The importer resolves them into `displays_field` / `displays_variable` edges, `display_calculation` instances and the [LayoutObjectSymbols](../../schema/catalog-tables/LayoutObjectSymbols.md) inventory.
- Folders and separators of the layout list appear as `<Layout>` entries with `isFolder`/`isSeparatorItem`; folder membership is carried by `<OwnerID>`.
- A layout on the **Classic** theme is written with an *empty* `<LayoutThemeReference/>` (no id/name/UUID attributes) — the importer resolves it into `Layouts.L_Theme_Resolved_*`.

**Extracted into:** [Layouts](../../schema/catalog-tables/Layouts.md) · [LayoutParts](../../schema/catalog-tables/LayoutParts.md) · [LayoutObjects](../../schema/catalog-tables/LayoutObjects.md) · [LayoutObjectConditions](../../schema/catalog-tables/LayoutObjectConditions.md) · [LayoutObjectSymbols](../../schema/catalog-tables/LayoutObjectSymbols.md) · [ScriptTriggers](../../schema/catalog-tables/ScriptTriggers.md) — column details in the [schema reference](../../schema/Schema.md).
