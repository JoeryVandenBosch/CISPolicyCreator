# Policy pack format

A policy pack is the reviewed boundary between a CIS Intune benchmark and Graph deployment.

## Manifest

```json
{
  "schemaVersion": "1.1",
  "id": "cis-product-version",
  "name": "Readable baseline name",
  "version": "1.0.0",
  "benchmarkScope": "microsoft-intune",
  "sourceDocumentIncluded": false,
  "recommendationsSpec": "spec/recommendations.json",
  "settingsCatalogPolicyDirectory": "policies/settings-catalog",
  "settingsCatalogSpec": "spec/settings-catalog.json",
  "graphObjects": "spec/graph-objects.json",
  "settingsCatalogProbe": null
}
```

`benchmarkScope` must be `microsoft-intune`. The importer refuses other values.

## Recommendation inventory

Every recommendation belongs in `spec/recommendations.json` with one of four states:

```json
{
  "recommendationId": "1.1",
  "profiles": ["L1"],
  "status": "unresolved",
  "implementationType": null,
  "implementationRefs": [],
  "notes": "Exact Intune mapping not proven yet."
}
```

Allowed states are `mapped`, `manual`, `unresolved`, and `not-applicable`.

Only `mapped` recommendations may be referenced by deployable objects.

## Settings Catalog policy bundle

```json
{
  "mappingStatus": "mapped",
  "recommendationIds": ["1.1", "1.2"],
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

If a bundle contains static settings, it must be `mapped` and list the recommendation IDs it implements.

Settings Catalog policies are created using **deep-create**: all settings are embedded in the initial POST. Empty policy creation is not used.

## Dynamic Settings Catalog spec

```json
{
  "recommendationId": "1.1",
  "mappingStatus": "mapped",
  "policy": "Example [L1]",
  "displayName": "Example security setting",
  "profiles": ["L1"],
  "resolve": {
    "definitionId": null,
    "baseUri": "./Device/Vendor/MSFT/Policy/Config/Area",
    "offsetUri": "Setting",
    "displayName": "Example security setting"
  },
  "value": {
    "kind": "choice",
    "desired": "Enabled",
    "optionId": null,
    "contains": "enabled",
    "exclude": null,
    "optionSuffix": "_1"
  }
}
```

Resolution order:

1. explicit `definitionId`;
2. exact `baseUri` + `offsetUri`;
3. exact display-name fallback;
4. canonical definition-ID lookup when a CSP path is available.

Choice selection prefers an explicit `optionId`. Controlled text/suffix selectors are fallbacks and must still resolve to exactly one option.

## Generic Graph objects

Reviewed Intune resources that are not Settings Catalog can be represented as generic Graph objects:

```json
{
  "name": "Example compliance [L1]",
  "mappingStatus": "mapped",
  "recommendationIds": ["4.1"],
  "profiles": ["L1"],
  "endpoint": "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies",
  "listEndpoint": "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?$select=id,displayName&$top=500",
  "nameProperty": "displayName",
  "payload": {
    "@odata.type": "#microsoft.graph.windows10CompliancePolicy",
    "displayName": "Example compliance [L1]"
  }
}
```

Safety restrictions:

- endpoint must be `https://graph.microsoft.com/(beta|v1.0)/deviceManagement/...`;
- assignment endpoints are rejected;
- payloads containing an `assignments` property are rejected;
- known read-only OData response metadata is removed before POST;
- existing objects are skipped, not updated.

## Profiles

Profile labels are explicit metadata. Convenience selector semantics:

- `L1` selects L1 objects;
- `L2` selects both L1 and L2 objects;
- `BL` selects BL objects;
- `L1BL` selects L1 plus BL;
- `All` selects everything.
