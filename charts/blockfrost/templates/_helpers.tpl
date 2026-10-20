{{/*
Expand the name of the chart.
*/}}
{{- define "blockfrost.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
Every object name derives from it, and Services must be DNS-1035 labels (start
with a letter). Helm accepts a release name starting with a digit, so that is
refused here, at render, rather than by the API server mid-install.
*/}}
{{- define "blockfrost.fullname" -}}
{{- $full := "" }}
{{- if .Values.fullnameOverride }}
{{- $full = .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- $full = .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $full = printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- if regexMatch "^[0-9]" $full }}
{{- fail (printf "release name %q gives object names starting with a digit (%q), which Kubernetes rejects for Services: set fullnameOverride (or nameOverride) to a name starting with a letter" .Release.Name $full) }}
{{- end }}
{{- $full }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "blockfrost.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "blockfrost.labels" -}}
helm.sh/chart: {{ include "blockfrost.chart" . }}
{{ include "blockfrost.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "blockfrost.selectorLabels" -}}
app.kubernetes.io/name: {{ include "blockfrost.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Object names. The two Services are the coordinates the workloads use to find each
other, so they are defined once here.
The base is truncated to leave room for the suffix BEFORE the suffix is appended:
truncating after would cut the suffix off a long fullname and give Dolos and the
Platform the same name (colliding Services, workloads and alert jobs).
The Dolos name is also the StatefulSet's, so it is capped at 52, not 63: the
controller labels each pod statefulset.kubernetes.io/pod-name=<sts>-<ordinal> and
controller-revision-hash=<sts>-<hash, up to 10 chars>, and a label value over 63
characters means the pods are never created. 46 + "-dolos" = 52.
*/}}
{{- define "blockfrost.dolosName" -}}
{{- printf "%s-dolos" (include "blockfrost.fullname" . | trunc 46 | trimSuffix "-") }}
{{- end }}

{{- define "blockfrost.platformName" -}}
{{- printf "%s-platform" (include "blockfrost.fullname" . | trunc 54 | trimSuffix "-") }}
{{- end }}

{{/*
Image reference: repository:tag@digest. The digest is what pins; the tag is kept
beside it for the human reading the manifest.
Call with (dict "image" .Values.<x>.image).
*/}}
{{- define "blockfrost.image" -}}
{{- $i := .image -}}
{{- if $i.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $i.digest) -}}
{{- fail (printf "image digest must be sha256:<64 hex chars>, got %q" $i.digest) -}}
{{- end -}}
{{ $i.repository }}:{{ $i.tag }}@{{ $i.digest }}
{{- else -}}
{{ $i.repository }}:{{ $i.tag }}
{{- end -}}
{{- end }}

{{/*
Per-network table — the ONE source for everything that differs by network. The
templates derive from `network` instead of shipping values-<network>.yaml presets,
because a deployer supplying values inline never opens a preset file.

magic is a STRING on purpose: fromYaml turns numbers into float64 and
764824073 would render as 7.64824073e+08.

Aggregator URLs, token registries and force_protocol come from Blockfrost's
docker/generate-dolos-config.sh (blockfrost-platform@19530a2).

Mithril keys are byte-identical to
IntersectMBO/mithril@2630.1-hotfix:mithril-infra/configuration/<env>/{genesis,ancillary}.vkey
with <env> = release-mainnet | release-preprod | pre-release-preview.
These are PUBLIC verification keys, published by the Mithril project for anyone
to verify certificates with. They are not secrets. preprod and preview share
one pair.

volumeSize: see dolos.storage in values.yaml for the basis of each figure. These
defaults are frozen once published (volumeClaimTemplates are immutable).
*/}}
{{- define "blockfrost.networkTable" -}}
mainnet:
  magic: "764824073"
  isTestnet: false
  aggregator: https://aggregator.release-mainnet.api.mithril.network/aggregator
  genesisKey: 5b3139312c36362c3134302c3138352c3133382c31312c3233372c3230372c3235302c3134342c32372c322c3138382c33302c31322c38312c3135352c3230342c31302c3137392c37352c32332c3133382c3139362c3231372c352c31342c32302c35372c37392c33392c3137365d
  ancillaryKey: 5b32332c37312c39362c3133332c34372c3235332c3232362c3133362c3233352c35372c3136342c3130362c3138362c322c32312c32392c3132302c3136332c38392c3132312c3137372c3133382c3230382c3133382c3231342c39392c35382c32322c302c35382c332c36395d
  tokenRegistryUrl: https://tokens.cardano.org
  forceProtocol: ""
  # UNMEASURED — Giovanni's ruling, probably too small; see values.yaml and T-408.
  volumeSize: 250Gi
preprod:
  magic: "1"
  isTestnet: true
  aggregator: https://aggregator.release-preprod.api.mithril.network/aggregator
  genesisKey: 5b3132372c37332c3132342c3136312c362c3133372c3133312c3231332c3230372c3131372c3139382c38352c3137362c3139392c3136322c3234312c36382c3132332c3131392c3134352c31332c3233322c3234332c34392c3232392c322c3234392c3230352c3230352c33392c3233352c34345d
  ancillaryKey: 5b3138392c3139322c3231362c3135302c3131342c3231362c3233372c3231302c34352c31382c32312c3139362c3230382c3234362c3134362c322c3235322c3234332c3235312c3139372c32382c3135372c3230342c3134352c33302c31342c3232382c3136382c3132392c38332c3133362c33365d
  tokenRegistryUrl: https://metadata.world.dev.cardano.org
  forceProtocol: ""
  # DERIVED from preview, not measured.
  volumeSize: 80Gi
preview:
  magic: "2"
  isTestnet: true
  aggregator: https://aggregator.pre-release-preview.api.mithril.network/aggregator
  genesisKey: 5b3132372c37332c3132342c3136312c362c3133372c3133312c3231332c3230372c3131372c3139382c38352c3137362c3139392c3136322c3234312c36382c3132332c3131392c3134352c31332c3233322c3234332c34392c3232392c322c3234392c3230352c3230352c33392c3233352c34345d
  ancillaryKey: 5b3138392c3139322c3231362c3135302c3131342c3231362c3233372c3231302c34352c31382c32312c3139362c3230382c3234362c3134362c322c3235322c3234332c3235312c3139372c32382c3135372c3230342c3134352c33302c31342c3232382c3136382c3132392c38332c3133362c33365d
  tokenRegistryUrl: https://metadata.world.dev.cardano.org
  forceProtocol: "6"
  # MEASURED: bootstrap peak 37.11 GiB.
  volumeSize: 60Gi
{{- end }}

{{/*
The table row for .Values.network, as a dict. Fails on any other network.
*/}}
{{- define "blockfrost.net" -}}
{{- $table := include "blockfrost.networkTable" . | fromYaml -}}
{{- if not (hasKey $table (toString .Values.network)) -}}
{{- fail (printf "network must be one of mainnet | preprod | preview, got %q" (toString .Values.network)) -}}
{{- end -}}
{{- get $table (toString .Values.network) | toYaml -}}
{{- end }}

{{/*
An upstream host, validated. It reaches socat's argv (where a ',' would append
socat address options) and dolos.toml, so only a DNS name, an IPv4 address or a
bracketed IPv6 address is accepted.
Call with (dict "host" .Values.upstream.nXn.host "key" "upstream.nXn.host").
*/}}
{{- define "blockfrost.upstreamHost" -}}
{{- $h := required (printf "%s is required: the address of an existing Cardano node endpoint" .key) .host | toString -}}
{{- if not (regexMatch "^(\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)$" $h) -}}
{{- fail (printf "%s must be a DNS name, an IPv4 address or a [bracketed] IPv6 address, got %q" .key $h) -}}
{{- end -}}
{{ $h }}
{{- end }}

{{/*
A TCP port, validated and rendered as an integer (int also defeats float64
scientific notation from values files).
Call with (dict "port" .Values.x "key" "x").
*/}}
{{- define "blockfrost.port" -}}
{{- $p := int .port -}}
{{- if or (lt $p 1) (gt $p 65535) -}}
{{- fail (printf "%s must be a TCP port 1-65535, got %v" .key .port) -}}
{{- end -}}
{{ $p }}
{{- end }}

{{/*
host:port coordinates of the two upstream endpoints.
*/}}
{{- define "blockfrost.n2nAddress" -}}
{{ include "blockfrost.upstreamHost" (dict "host" .Values.upstream.n2n.host "key" "upstream.n2n.host") }}:{{ include "blockfrost.port" (dict "port" .Values.upstream.n2n.port "key" "upstream.n2n.port") }}
{{- end }}

{{- define "blockfrost.n2cAddress" -}}
{{ include "blockfrost.upstreamHost" (dict "host" .Values.upstream.n2c.host "key" "upstream.n2c.host") }}:{{ include "blockfrost.port" (dict "port" .Values.upstream.n2c.port "key" "upstream.n2c.port") }}
{{- end }}

{{/*
Fixed in-pod paths shared by the ConfigMap and the workloads.
*/}}
{{- define "blockfrost.dolosDataPath" -}}/data{{- end }}
{{- define "blockfrost.dolosConfigDir" -}}/etc/dolos{{- end }}
{{- define "blockfrost.nodeSocketPath" -}}/ipc/node.socket{{- end }}

{{/*
The bootstrap download directory, validated: relative to the data volume. Dolos
DELETES the download dir after a successful bootstrap, so "", "." or anything
escaping with ".." would point that deletion at the data itself. Nor may it sit
inside one of the store directories Dolos itself writes on the same volume
(archive, index, state, wal — the layout measured after a v1.6.1 bootstrap).
Nor may its first component start with "." — it could then alias the bootstrap
marker (.blockfrost-bootstrap-complete) at the data root: a download directory
left there would read as a mismatched marker and crashloop every later start.
*/}}
{{- define "blockfrost.downloadDir" -}}
{{- $d := toString .Values.dolos.bootstrap.downloadDir -}}
{{- if or (eq $d "") (hasPrefix "/" $d) (regexMatch "(^|/)\\.\\.?(/|$)" $d) (not (regexMatch "^[A-Za-z0-9._/-]+$" $d)) -}}
{{- fail (printf "dolos.bootstrap.downloadDir must be a plain relative path inside the data volume (not empty, no \".\" or \"..\" components), got %q" $d) -}}
{{- end -}}
{{- if hasPrefix "." $d -}}
{{- fail (printf "dolos.bootstrap.downloadDir must not have a first path component starting with \".\": it could alias the bootstrap marker .blockfrost-bootstrap-complete, which would crashloop every later start, got %q" $d) -}}
{{- end -}}
{{- if regexMatch "^(archive|index|state|wal)(/|$)" $d -}}
{{- fail (printf "dolos.bootstrap.downloadDir must not be, or be inside, a Dolos store directory (archive, index, state, wal): Dolos deletes the download dir after bootstrap, got %q" $d) -}}
{{- end -}}
{{ $d }}
{{- end }}

{{/*
The content of the bootstrap marker. Records WHICH store was bootstrapped, so a
volume reused across networks or storage versions is refused instead of served.
*/}}
{{- define "blockfrost.markerContent" -}}
{{- $net := include "blockfrost.net" . | fromYaml -}}
magic={{ $net.magic }} storage=v3
{{- end }}
