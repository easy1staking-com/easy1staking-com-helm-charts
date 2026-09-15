{{- define "sundae-scooper-v2.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sundae-scooper-v2.fullname" -}}
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

{{- define "sundae-scooper-v2.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
⛔ REQUIRED, and appVersion is a record rather than a fallback.

⚠ THE GHCR TAG HAS NO `v`: `0.7.1`, not `v0.7.1` — the latter is a 404, and
upstream's own README example uses it. Verified against the registry 2026-09-15.

⚠ AND I HAVE CORRECTED A CLAIM THAT WAS HERE: an earlier version of this comment
said a scooper roster "generally runs a common build", which I carried over from
a different project's MEASURED behaviour. scooper-v2 has no peer-version
comparison — searched, zero hits for roster or version-mismatch handling. The
reason to pin is the ordinary one: `latest` and `main` both move, and you want to
know what you are running.
*/}}
{{- define "sundae-scooper-v2.imageTag" -}}
{{- required "sundae-scooper-v2: image.tag is REQUIRED and has no default. Upstream publishes to ghcr.io/sundaeswap-finance/scooper-v2 with NO `v` prefix — `0.7.1`, not `v0.7.1` (that is the git release tag and a 404 as an image tag; upstream's README example gets this wrong). Newest verified 2026-09-15: 0.7.1." .Values.image.tag -}}
{{- end }}

{{- define "sundae-scooper-v2.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "sundae-scooper-v2.imageTag" .) -}}
{{- end }}

{{/*
⛔ REQUIRED, and the whole point of the chart being multi-network. Upstream's
required setting is `acropolis.global.startup.network-name`.
*/}}
{{- define "sundae-scooper-v2.network" -}}
{{- required "sundae-scooper-v2: network is REQUIRED. It sets acropolis.global.startup.network-name and selects which upstream config you must supply. values-preview.yaml sets it to `preview`." .Values.network -}}
{{- end }}

{{- define "sundae-scooper-v2.labels" -}}
helm.sh/chart: {{ include "sundae-scooper-v2.chart" . }}
{{ include "sundae-scooper-v2.selectorLabels" . }}
app.kubernetes.io/version: {{ include "sundae-scooper-v2.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "sundae-scooper-v2.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sundae-scooper-v2.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
⛔ INTEGER-SAFE. Helm parses values-file numbers as float64, so a large one
renders in scientific notation — `1.65e+07` where JSON wants 16500000. `--set`
yields int64 and renders fine, so the two input paths DISAGREE and the
values-file path is the broken one. Route every numeric through this.
*/}}
{{- define "sundae-scooper-v2.num" -}}
{{- $v := . -}}
{{- if kindIs "float64" $v -}}
{{- if eq $v (floor $v) -}}{{- printf "%.0f" $v -}}{{- else -}}{{- printf "%v" $v -}}{{- end -}}
{{- else -}}{{- printf "%v" $v -}}{{- end -}}
{{- end }}
