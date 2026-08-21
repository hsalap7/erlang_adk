{{- define "erlang-adk.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "erlang-adk.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "erlang-adk.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "erlang-adk.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "erlang-adk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "erlang-adk.selectorLabels" -}}
app.kubernetes.io/name: {{ include "erlang-adk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "erlang-adk.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "erlang-adk.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "erlang-adk.image" -}}
{{- printf "%s@%s" (required "image.repository is required" .Values.image.repository) (required "image.digest is required" .Values.image.digest) }}
{{- end }}
