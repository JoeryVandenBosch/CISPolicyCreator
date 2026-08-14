# Policy pack format v2

A generated pack is the deterministic, public-safe deployment boundary between a private CIS Intune PDF and Microsoft Graph.

## Build inputs

The compiler consumes four independently auditable inputs. The mapping catalog declares an expected recommendation count and explicitly classifies every extracted recommendation, including unresolved entries:

1. private extraction produced from the user-supplied PDF;
2. reviewed versioned mapping catalog;
3. pinned Settings Catalog definition snapshot when settings are mapped;
4. explicit administrator decisions when the catalog contains `requires-input` records.

Private `*.private-review.json` candidate worklists and `*.private-approvals.json` reviewer records are not compiler inputs and are never part of a pack. Candidate title matches do not authorize a definition ID, option ID, value, or `mappingStatus` change. An approval may produce a new reviewed catalog only after exact hashes, candidate occurrence, full setting tree, benchmark-prescribed value basis, and unassigned policy metadata are revalidated.

Schemas for all inputs live under `schemas/`. Input paths and raw extraction text are not copied into the generated pack.

## Manifest

Schema version `2.0` records source and build provenance:

```json
{
  "schemaVersion": "2.0",
  "id": "cis-product-version",
  "name": "Readable baseline name",
  "version": "1.0.0",
  "benchmarkScope": "microsoft-intune",
  "sourceDocumentIncluded": false,
  "source": {
    "fileName": "Benchmark.pdf",
    "sha256": "<64 lowercase hex characters>",
    "pageCount": 100
  },
  "build": {
    "toolVersion": "0.2.0",
    "extractorVersion": "0.2.1",
    "pdfParser": "pypdf",
    "pdfParserVersion": "6.15.0",
    "mappingCatalogId": "catalog-id",
    "mappingCatalogVersion": "1.0.0",
    "mappingCatalogSha256": "<sha256>",
    "administratorDecisionsSha256": null,
    "settingsCatalogSnapshotSha256": "<sha256>"
  },
  "recommendationsSpec": "spec/recommendations.json",
  "settingsCatalogPolicyDirectory": "policies/settings-catalog",
  "settingsCatalogSpec": "spec/settings-catalog.json",
  "graphObjects": "spec/graph-objects.json",
  "settingsCatalogProbe": null
}
```

All manifest paths must be relative and remain inside the pack root.

## Recommendation inventory

```json
{
  "recommendationId": "1.1",
  "profiles": ["L1"],
  "cisAssessmentMethod": "Manual",
  "mappingStatus": "mapped",
  "implementationType": "settings-catalog",
  "implementationRefs": ["settings-catalog:example"],
  "notes": "Deterministic Intune implementation reviewed."
}
```

For a resolved organizational decision:

```json
{
  "recommendationId": "1.2",
  "profiles": ["L1"],
  "cisAssessmentMethod": "Automated",
  "mappingStatus": "mapped",
  "catalogMappingStatus": "requires-input",
  "decisionRef": "retention-days",
  "implementationType": "settings-catalog",
  "implementationRefs": ["settings-catalog:example"],
  "notes": "Administrator selected an allowed value."
}
```

Without a decision, `mappingStatus` remains `requires-input` and no deployable object may reference it.

## Settings Catalog policy bundle

Policy bundles contain policy metadata but no raw static settings:

```json
{
  "mappingStatus": "mapped",
  "recommendationIds": ["1.1"],
  "profiles": ["L1"],
  "policy": {
    "name": "Example [L1]",
    "description": "Implementation description",
    "platforms": "windows10",
    "technologies": "mdm",
    "roleScopeTagIds": ["0"]
  },
  "settings": []
}
```

Settings are assembled through the validated dynamic specification and embedded in the initial deep-create POST.

## Validated Settings Catalog setting

```json
{
  "recommendationId": "1.1",
  "mappingStatus": "mapped",
  "policy": "Example [L1]",
  "displayName": "Example security setting",
  "profiles": ["L1"],
  "resolve": {
    "definitionId": "reviewed_definition_id",
    "baseUri": "./Device/Vendor/MSFT/Policy/Config/Area",
    "offsetUri": "Setting",
    "expectedType": "#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition"
  },
  "value": {
    "kind": "choice",
    "optionId": "reviewed_exact_option_id"
  }
}
```

The compiler obtains `definitionId` from the pinned snapshot using either a reviewed explicit ID or an exact unique CSP tuple. Choice `optionId` is always explicit. Display-name, substring, suffix, and constructed-ID fallback fields are not part of schema v2.

Simple collections use an explicitly typed, ordered value list:

```json
{
  "kind": "string-collection",
  "values": ["reviewed-value-a", "reviewed-value-b"]
}
```

Choice-dependent settings and group collections use recursive reviewed nodes. Every child has its own resolver and expected definition type:

```json
{
  "kind": "group-collection",
  "items": [
    {
      "children": [
        {
          "displayName": "Reviewed child",
          "resolve": {
            "definitionId": "reviewed_child_definition_id",
            "baseUri": null,
            "offsetUri": null,
            "expectedType": "#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition"
          },
          "value": {
            "kind": "choice",
            "optionId": "reviewed_exact_child_option_id"
          }
        }
      ]
    }
  ]
}
```

Supported value kinds are `choice`, `integer`, `string`, `integer-collection`, `string-collection`, and `group-collection`. A choice may contain `children`; group items contain `children` and may repeat the same child definitions in different rows. The compiler and live importer validate the complete tree to a bounded depth. Incompatible extra fields, duplicate children within one value, missing definitions, type mismatches, out-of-range values, and non-exact option IDs fail closed.

## Generic Graph objects

Generic objects remain restricted to reviewed Microsoft Graph `deviceManagement` create endpoints. They must reference only final `mapped` recommendations, may contain exact decision markers during catalog authoring, and cannot contain assignment data. Existing objects are skipped rather than updated.

## Profiles

- `L1` selects L1 objects;
- `L2` selects L1 and L2 objects;
- `BL` selects BL objects;
- `L1BL` selects L1 plus BL;
- `All` selects everything.

Every deployable object's profile metadata must be declared by each referenced recommendation.
