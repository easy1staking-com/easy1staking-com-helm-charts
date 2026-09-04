{{/*
Expand the name of the chart.
*/}}
{{- define "ft-aquarium-node.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ft-aquarium-node.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ft-aquarium-node.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ft-aquarium-node.labels" -}}
helm.sh/chart: {{ include "ft-aquarium-node.chart" . }}
{{ include "ft-aquarium-node.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ft-aquarium-node.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ft-aquarium-node.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Image reference.

A digest pins; a tag only describes. When image.digest is set it wins and the
tag is not rendered at all, because "repo:tag@sha256:..." invites the reader to
believe the tag was verified when only the digest was.
*/}}
{{- define "ft-aquarium-node.image" -}}
{{- if .Values.image.digest -}}
{{- /*
  A digest identifies a manifest inside ONE repository, so it is only meaningful
  next to the repository it came from. Two guards, because the silent version of
  each has no defensible reading:

  - digest AND an explicit tag: refuse. The digest would win and the tag would
    look applied. An operator who set a tag expects the tag.
  - a digest that is not sha256:<64 hex>: refuse. Catches a truncated paste and a
    config digest mistaken for a manifest digest early, rather than at pull time.

  What the chart CANNOT check is whether the digest belongs to the configured
  repository — it has no way to know. That is why the default is empty; see the
  warning at image.digest in values.yaml.
*/ -}}
{{- if .Values.image.tag -}}
{{- fail "image.digest and image.tag are both set: a digest pin ignores the tag. Set one or the other." -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .Values.image.digest) -}}
{{- fail (printf "image.digest must be sha256:<64 hex chars>, got %q" .Values.image.digest) -}}
{{- end -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end }}

{{/*
JDBC URL.

Composed from host/port/database/schema so the URL cannot drift from the parts
it is built out of; config.db.url overrides the composition wholesale.
*/}}
{{- define "ft-aquarium-node.dbUrl" -}}
{{- with .Values.config.db -}}
{{- if .url -}}
{{ .url }}
{{- else -}}
jdbc:postgresql://{{ include "ft-aquarium-node.dbHost" $ }}:{{ .port }}/{{ .database }}?currentSchema={{ .schema }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Emit one env var, only when the value is set.

`toString` then `empty` rather than a bare truthiness test, so a YAML boolean and
a quoted string behave alike and an explicit `false` or `0` reaches the container
instead of being dropped as falsy. Unset means THE CHART SAYS NOTHING and the
image's own per-profile default governs — which is a different and safer state
than the chart asserting that default itself, because it cannot go stale.
*/}}
{{- define "ft-aquarium-node.env" -}}
{{- $v := .value -}}
{{- /*
  ⛔ HELM PARSES EVERY NUMBER FROM A VALUES FILE AS float64, and `toString` on a
  large float64 yields SCIENTIFIC NOTATION. Before this guard,
  `profitMarginLovelace: 1500000` in a values file reached the container as
  "1.5e+06" — which no Java long parses, so the pod failed at boot. It only
  looked fine because `--set` takes a different path and yields an int64.

  Integral floats are therefore reformatted with %.0f. A genuinely fractional
  value is left alone: nothing in this chart is fractional today, and silently
  truncating one would be worse than passing it through.
*/ -}}
{{- if kindIs "float64" $v -}}
{{- if eq $v (floor $v) -}}
{{- $v = printf "%.0f" $v -}}
{{- end -}}
{{- end -}}
{{- /*
  `kindIs "invalid"` is the nil test. `toString nil` is the STRING "<nil>", which
  is not empty, so an absent key would otherwise be emitted as literal "<nil>".
*/ -}}
{{- if not (kindIs "invalid" $v) }}
{{- if not (empty (toString $v)) }}
            - name: {{ .name }}
              value: {{ toString $v | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Every env var name this chart emits from a typed values key.

Used to refuse an extraEnv entry that collides with one of them. A passthrough
map that silently shadows a documented default is worse than no documentation,
because the reader now has false confidence in the value they can see.
*/}}
{{- define "ft-aquarium-node.typedEnvNames" -}}
SPRING_PROFILES_ACTIVE,SPRING_CONFIG_IMPORT,JAVA_TOOL_OPTIONS,DB_DRIVER,DB_DIALECT,POSTGRES_HOST,POSTGRES_PORT,POSTGRES_DB,DB_SCHEMA,DB_USERNAME,DB_URL,WALLET_MNEMONIC,BLOCKFROST_KEY,DB_PASSWORD,STORE_CARDANO_HOST,STORE_CARDANO_PORT,STORE_CARDANO_PROTOCOL_MAGIC,STORE_CARDANO_KEEP_ALIVE_INTERVAL,STORE_CARDANO_SYNC_START_SLOT,STORE_CARDANO_SYNC_START_BLOCKHASH,MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE,APIPREFIX,STORE_CARDANO_CURSOR_CLEANUP_INTERVAL,STORE_CARDANO_CURSOR_NO_OF_BLOCKS_TO_KEEP,NETWORK,BLOCKFROST_URL,LOANS_ORACLE_ENABLED,LOANS_ORACLE_URL,LOANS_CONFIG_POLICY_ID,LOANS_CONFIG_REF_UTXO_TX_HASH,LOANS_CONFIG_ASSET_NAME,LOANS_LM_CONFIG_POLICY_ID,LOANS_SMART_TOKENS_SPEND_SCRIPT_HASH,LOANS_VERIFY_CONFIG_FAIL_ON_UNREACHABLE,AQUARIUM_GENESIS_TX_HASH,AQUARIUM_GENESIS_OUTPUT_INDEX,AQUARIUM_STAKING_TOKEN_POLICY,AQUARIUM_STAKING_TOKEN_NAME,AQUARIUM_TANK_REF_INPUT_TXHASH,AQUARIUM_TANK_REF_INPUT_OUTPUTINDEX,AQUARIUM_LIQUIDATION_MODE,AQUARIUM_LIQUIDATION_IGNORE_PROFIT_CHECK,AQUARIUM_LIQUIDATION_CHECK_PROFITABILITY,AQUARIUM_LIQUIDATION_PROFIT_MARGIN_LOVELACE,AQUARIUM_LIQUIDATION_MIN_PROFIT_ABSOLUTE_LOVELACE,AQUARIUM_LIQUIDATION_MIN_EXPECTED_PROFIT_LOVELACE,AQUARIUM_LIQUIDATION_DELAY_SECONDS,AQUARIUM_LIQUIDATION_VALIDITY_WINDOW_SECONDS,AQUARIUM_LIQUIDATION_ORACLE_MARGIN_SECONDS,AQUARIUM_LIQUIDATION_QUARANTINE_MINUTES,AQUARIUM_LIQUIDATION_DECISION_LOG_SIZE,AQUARIUM_LIQUIDATION_REF_LOAN,AQUARIUM_LIQUIDATION_REF_LOAN_SPEND,AQUARIUM_LIQUIDATION_REF_LENDER_MANAGER,AQUARIUM_LIQUIDATION_REF_LENDER_MANAGER_SPEND,AQUARIUM_LIQUIDATION_REF_LOAN_CLAIM_ACTION,AQUARIUM_LIQUIDATION_REF_LM_LIQUIDATE_ACTION,AQUARIUM_LIQUIDATION_REF_LM_LIQUIDATE_AND_PAY_IN_ADVANCE_ACTION,AQUARIUM_LIQUIDATION_REF_ASSET_MANAGER,LOANS_MINSWAP_POOL_POLICY_ID,LOANS_MINSWAP_POOL_SPEND_SCRIPT_HASH,LOANS_MINSWAP_ORDER_SPEND_SCRIPT_HASH,LOANS_MINSWAP_POOL_ADDRESS,LOANS_LIQUIDATION_CONVERT_ENABLED,LOANS_LIQUIDATION_CONVERT_PROFIT_MARGIN_LOVELACE,LOANS_LIQUIDATION_CONVERT_DEX_COST_FLOOR_LOVELACE,LOANS_LIQUIDATION_REFERENCE_SCRIPTS_LM_LIQUIDATE_AND_CONVERT_ACTION,LOANS_UI_ENABLED,AQUARIUM_COMPOUND_ENABLED,AQUARIUM_COMPOUND_DELAY_SECONDS,AQUARIUM_COMPOUND_PROFIT_MARGIN_LOVELACE,AQUARIUM_COMPOUND_REFERENCE_SCRIPTS,SCHEDULING_TRANSACTION_PROCESSOR_DELAY_MINUTES,SPRING_TASK_SCHEDULING_POOL_SIZE
{{- end }}

{{/*
The Secret the Zalando operator generates for a role.

Its name is fixed by the operator's own convention,
`{user}.{cluster}.credentials.postgresql.acid.zalan.do`, so it is DERIVED from
the same values that name the CR rather than restated. A restated name goes
stale the moment someone renames the cluster, and the failure is a pod stuck in
CreateContainerConfigError naming a Secret nobody typed.
*/}}
{{- define "ft-aquarium-node.zalandoSecretName" -}}
{{- printf "%s.%s.credentials.postgresql.acid.zalan.do" .Values.postgres.username .Values.postgres.clusterName -}}
{{- end }}

{{/*
The database host, resolved once.

Empty `config.db.host` with `postgres.enabled` means the operator's cluster
service, which the operator names after the cluster. Derived rather than
restated so the CR and the connection cannot drift — and resolved in ONE place
because the host is read three times (the JDBC URL, POSTGRES_HOST, and the
wait-for-postgres probe) and three copies of a fallback is three chances to
disagree.
*/}}
{{- define "ft-aquarium-node.dbHost" -}}
{{- if .Values.config.db.host -}}
{{ .Values.config.db.host }}
{{- else if .Values.postgres.enabled -}}
{{ .Values.postgres.clusterName }}
{{- end -}}
{{- end }}
