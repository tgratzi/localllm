{{- /* Fixed name, not the release name: other apps call http://localllm:8080 and mount
       Secret localllm-api-key, so these must not depend on how the release was installed. */}}
{{- define "localllm.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "localllm.labels" -}}
app: {{ include "localllm.name" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- define "localllm.secretName" -}}
{{- default (printf "%s-api-key" (include "localllm.name" .)) .Values.apiKey.existingSecret -}}
{{- end -}}
