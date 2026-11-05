# How propagate Workload Identity Federation (WIF) to a specific Kubernetes Service Account (KSA)


To propagate Workload Identity Federation (WIF) to a specific Kubernetes Service Account (KSA) in OpenShift Dedicated (OSD), you connect the KSA's native token to a Google Service Account (GSA) using a GCP Workload Identity Pool.

Here is the complete end-to-end configuration using `gcloud` and Kubernetes YAML.

---

### Step 1: Discover the Cluster OIDC Issuer

Extract the OIDC Issuer URL from your OSD cluster.

```bash
ISSUER_URL=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}')
echo "OIDC Issuer URL: ${ISSUER_URL}"

```

---

### Step 2: Configure GCP Workload Identity Pool & Provider

Set up a Workload Identity Pool and map the OIDC claims coming from OpenShift.

```bash
PROJECT_ID="your-gcp-project-id"
POOL_ID="osd-apps-pool"
PROVIDER_ID="osd-oidc-provider"

# 1. Create the Workload Identity Pool
gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="OSD Applications Pool"

# 2. Add the OIDC Provider referencing the OSD cluster's issuer
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --issuer-uri="${ISSUER_URL}" \
    --allowed-audiences="${ISSUER_URL}" \
    --attribute-mapping="google.subject=assertion.sub,attribute.namespace=assertion['kubernetes.io']['namespace'],attribute.serviceaccount=assertion['kubernetes.io']['serviceaccount']['name']"

```

---

### Step 3: Grant IAM Impersonation to the Specific KSA

Create the target Google Service Account (GSA) and bind the `roles/iam.workloadIdentityUser` role strictly to your specific OpenShift namespace and Service Account.

```bash
GSA_NAME="gcs-reader-sa"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# 1. Create the Google Service Account
gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="App GCS Reader Service Account"

# 2. Assign resource permissions to the GSA (e.g., read access to a storage bucket)
gcloud storage buckets add-iam-policy-binding gs://your-target-bucket \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="roles/storage.objectViewer"

# 3. Retrieve the GCP Project Number
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")

# 4. Bind the role directly to namespace "analytics" and KSA "data-processor-sa"
TARGET_NAMESPACE="analytics"
TARGET_KSA="data-processor-sa"

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/subject/system:serviceaccount:${TARGET_NAMESPACE}:${TARGET_KSA}"

```

---

### Step 4: Generate the Client Credential Configuration

Generate the WIF credential configuration file that the Google Cloud Client Libraries use to exchange tokens automatically.

```bash
gcloud iam workload-identity-pools create-cred-config \
    "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}" \
    --service-account="${GSA_EMAIL}" \
    --service-account-token-type="urn:ietf:params:oauth:token-type:jwt" \
    --credential-source-file="/var/run/secrets/tokens/gcp-token" \
    --output-file="credential-configuration.json"

```

Push this configuration file into a `ConfigMap` in the target namespace:

```bash
oc create configmap gcp-wif-config \
    --from-file=credential-configuration.json=credential-configuration.json \
    -n ${TARGET_NAMESPACE}

```

---

### Step 5: OpenShift Workload Manifest

Deploy the application using standard Kubernetes token projection. Notice that no long-lived secret keys are mounted.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: data-processor-sa
  namespace: analytics
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gcs-processor
  namespace: analytics
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gcs-processor
  template:
    metadata:
      labels:
        app: gcs-processor
    spec:
      serviceAccountName: data-processor-sa
      containers:
      - name: processor
        image: google/cloud-sdk:slim
        command:
        - "/bin/bash"
        - "-c"
        - |
          echo "Testing Workload Identity Federation..."
          gcloud auth list
          gcloud storage ls gs://your-target-bucket/
          sleep infinity
        env:
        # Directs Google SDK/Client libraries to the WIF configuration file
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /etc/gcp/credential-configuration.json
        volumeMounts:
        # 1. Mount the client config
        - name: wif-config
          mountPath: /etc/gcp
          readOnly: true
        # 2. Mount the short-lived projected token
        - name: gcp-token-volume
          mountPath: /var/run/secrets/tokens
          readOnly: true
      volumes:
      - name: wif-config
        configMap:
          name: gcp-wif-config
      - name: gcp-token-volume
        projected:
          sources:
          - serviceAccountToken:
              path: gcp-token
              expirationSeconds: 3600
              # Must match the audience configured in the OIDC provider (Issuer URL)
              audience: "https://<your-cluster-oidc-issuer-url>"

```

### Verification

Once the pod starts, inspect the logs:

```bash
oc logs deployment/gcs-processor -n analytics

```

*Expected Result:* `gcloud auth list` displays `${GSA_EMAIL}` with an active status, and `gcloud storage ls` outputs the bucket contents without authentication errors.
