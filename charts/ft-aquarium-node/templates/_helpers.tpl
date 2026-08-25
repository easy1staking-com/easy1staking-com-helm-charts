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
jdbc:postgresql://{{ .host }}:{{ .port }}/{{ .database }}?currentSchema={{ .schema }}
{{- end -}}
{{- end -}}
{{- end }}
