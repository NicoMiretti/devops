{{/* vim: set filetype=gotpl: */}}
{{/*
Genera el nombre completo del chart.
*/}}
{{- define "app-component.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Genera el nombre de la service account a usar.
*/}}
{{- define "app-component.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "app-component.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Etiquetas comunes del chart.
*/}}
{{- define "app-component.labels" -}}
helm.sh/chart: {{ include "app-component.fullname" . }}
app.kubernetes.io/name: {{ include "app-component.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
