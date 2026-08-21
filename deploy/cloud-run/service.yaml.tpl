apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: @@SERVICE@@
  annotations:
    run.googleapis.com/ingress: internal-and-cloud-load-balancing
    run.googleapis.com/maxScale: "@@MAX_INSTANCES@@"
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "0"
        autoscaling.knative.dev/maxScale: "@@MAX_INSTANCES@@"
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/startup-cpu-boost: "true"
    spec:
      containerConcurrency: 1
      timeoutSeconds: 300
      serviceAccountName: @@SERVICE_ACCOUNT@@
      containers:
        - name: erlang-adk
          image: @@IMAGE@@
          ports:
            - name: http1
              containerPort: @@PORT@@
          env:
            - name: RELX_CONFIG_PATH
              value: /opt/erlang_adk/etc/health-http.sys.config
            - name: RELX_OUT_FILE_PATH
              value: /tmp/erlang_adk
            - name: ERLANG_ADK_DATA_DIR
              value: /var/lib/erlang_adk
            - name: ERLANG_ADK_LOG_DIR
              value: /var/log/erlang_adk
            - name: ERLANG_ADK_TMP_DIR
              value: /tmp/erlang_adk
            - name: ERLANG_ADK_DRAIN_TIMEOUT_MS
              value: "3000"
          resources:
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: runtime-data
              mountPath: /var/lib/erlang_adk
            - name: runtime-log
              mountPath: /var/log/erlang_adk
            - name: runtime-tmp
              mountPath: /tmp/erlang_adk
          startupProbe:
            tcpSocket:
              port: @@PORT@@
            initialDelaySeconds: 0
            timeoutSeconds: 2
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            tcpSocket:
              port: @@PORT@@
            timeoutSeconds: 2
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: runtime-data
          emptyDir:
            medium: Memory
            sizeLimit: 512Mi
        - name: runtime-log
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
        - name: runtime-tmp
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
