{{/*
Expand the name of the chart.
*/}}
{{- define "bitrix.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "bitrix.fullname" -}}
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
Secret name (фиксированное имя для совместимости с kubectl примерами).
*/}}
{{- define "bitrix.secretName" -}}
{{- default "bitrix" .Values.secretNameOverride }}
{{- end }}

{{/*
Chart label version.
*/}}
{{- define "bitrix.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "bitrix.labels" -}}
helm.sh/chart: {{ include "bitrix.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ quote . }}
{{- end }}
app.kubernetes.io/name: {{ include "bitrix.name" . }}
{{- end }}

{{/*
Target namespace = release namespace
*/}}
{{- define "bitrix.namespace" -}}
{{- .Release.Namespace }}
{{- end }}
