This comprehensive guide provides the complete setup for **Red Hat OpenShift Service Mesh 3 (Ambient Mode)** on **ROSA**, covering the deployment of **Keycloak**, the **OAuth2-Proxy**, and the protection of two "Hello World" scenarios.

In **Service Mesh 3 (Ambient Mode)**,  two Custom Resources (CRs) `RequestAuthentication` and `AuthorizationPolicy` work together to create a secure environment. While they are related, they perform fundamentally different roles in the "Authentication vs. Authorization" workflow.

---

## 1. RequestAuthentication (The "Who")
The `RequestAuthentication` CR is used to define **how** a request should be authenticated. It specifically handles the validation of JSON Web Tokens (JWT).

* **Credential Validation**: It checks if a JWT is present in the request and verifies its signature using the public keys (JWKS) provided by an OIDC provider like Keycloak.
* **Identity Extraction**: If the token is valid, Istio extracts the identity (the `sub` or `requestPrincipal`) and stores it in the request context for later use by other policies.
* **Behavior on Missing Tokens**: By default, if a request has **no token**, `RequestAuthentication` does nothing and lets the request proceed. It only fails if a token is present but **invalid** (e.g., expired or wrong signature).

## 2. AuthorizationPolicy (The "What")
The `AuthorizationPolicy` CR defines **what** an authenticated (or unauthenticated) user is allowed to do.

* **Access Control**: It acts as a gatekeeper that allows or denies requests based on criteria like paths, methods, or the identity extracted by the `RequestAuthentication`.
* **Action Enforcement**: It can be set to `ALLOW`, `DENY`, or `CUSTOM` (for redirects).
* **Principal Verification**: It checks the `requestPrincipals` field to ensure the caller has a valid identity from your specific Keycloak realm.

---

## Can I use RequestAuthentication without AuthorizationPolicy?

**Technically yes, but it won't be secure.**

If you apply **only** `RequestAuthentication`, your mesh will validate tokens if they are sent, but it will **not block** requests that have no token at all. 

* **Result**: An attacker could simply omit the `Authorization` header and bypass your security entirely because there is no `AuthorizationPolicy` telling the mesh to reject "anonymous" traffic.
* **Best Practice**: You must use them in tandem. `RequestAuthentication` verifies the token's validity, and `AuthorizationPolicy` makes that token **mandatory** for access.

---

## 1. Prerequisites: Mesh & Permissions

### 1.1 Initialize the Control Plane
The **Sail Operator** manages the lifecycle. We define the `oauth2-auth` provider in the mesh configuration so all Waypoint proxies know how to communicate with the security proxy.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.24.1
  profile: ambient
  values:
    meshConfig:
      extensionProviders:
        - name: "oauth2-auth"
          envoyExtAuthzHttp:
            service: "oauth2-proxy.hello-security.svc.cluster.local"
            port: 4180
            includeRequestHeadersInCheck: ["authorization", "cookie"]
```

### 1.2 Grant CNI Permissions
ROSA requires explicit permission for the Istio CNI to manage node networking.
```bash
oc adm policy add-scc-to-user privileged -z istio-cni -n istio-system
```

---

## 2. Infrastructure: Keycloak & Database

### 2.1 Setup Namespace and Database
```bash
oc create namespace keycloak
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-db-secret
  namespace: keycloak
stringData:
  username: keycloak
  password: Password123!
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-keycloak
  namespace: keycloak
spec:
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: registry.redhat.io/rhel9/postgresql-15:latest
          env:
            - name: POSTGRESQL_DATABASE
              value: keycloak
            - name: POSTGRESQL_USER
              valueFrom: { secretKeyRef: { name: keycloak-db-secret, key: username } }
            - name: POSTGRESQL_PASSWORD
              valueFrom: { secretKeyRef: { name: keycloak-db-secret, key: password } }
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-db 
  namespace: keycloak
spec:
  selector:
    app: postgres 
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
```

### 2.2 Deploy Keycloak
Adapt the `hostname` to match your ROSA cluster's base domain.

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: hello-keycloak
  namespace: keycloak
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-db.keycloak.svc.cluster.local
    usernameSecret: { name: keycloak-db-secret, key: username }
    passwordSecret: { name: keycloak-db-secret, key: password }
  hostname:
    hostname: keycloak.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com
  proxy:
    headers: xforwarded
  additionalOptions:
    - name: http-enabled
      value: "true"
```

### 2.3 Automated Realm Import
```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: hello-realm-import
  namespace: keycloak
spec:
  keycloakCRName: hello-keycloak
  realm:
    realm: hello-realm
    enabled: true
    users:
      - username: workshop-user
        enabled: true
        credentials: [{ type: password, value: "Password123!", temporary: false }]
    clients:
      - clientId: hello-client
        enabled: true
        directAccessGrantsEnabled: true
        secret: "zsQoTVnXQqqOhdwrqmiwICob5MgzwKFd"
        redirectUris: ["https://*"]
```

---

## 3. Tutorial 1: Direct JWT Validation (CLI)

### 3.1 Deploy Workload & Waypoint
```bash
oc create namespace hello-direct
oc label namespace hello-direct istio.io/dataplane-mode=ambient
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-service
  namespace: hello-direct
spec:
  replicas: 1
  selector:
    matchLabels: { app: hello }
  template:
    metadata:
      labels: { app: hello }
    spec:
      containers:
      - name: hello
        image: bitnami/nginx:latest
        ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: hello-service
  namespace: hello-direct
spec:
  selector: { app: hello }
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: hello-waypoint
  namespace: hello-direct
  labels: { istio.io/waypoint-for: service }
spec:
  gatewayClassName: istio-waypoint
  listeners: [{ name: mesh, port: 15008, protocol: HBONE }]
```

### 3.2 Apply Security Policies
```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-verify
  namespace: hello-direct
spec:
  targetRefs: [{ kind: Service, name: hello-service }]
  jwtRules:
  - issuer: "https://keycloak.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com/realms/hello-realm"
    jwksUri: "http://hello-keycloak-service.keycloak.svc.cluster.local:8080/realms/hello-realm/protocol/openid-connect/certs"
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: hello-direct
spec:
  targetRefs: [{ kind: Service, name: hello-service }]
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://keycloak.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com/realms/hello-realm/*"]
```

### 3.3 CLI Testing
1. Start a test pod: `oc run curl-test --image=fedora -n hello-direct -- sleep 3600`
2. Install jq: `oc exec curl-test -n hello-direct -- dnf install -y jq`
3. Test blocked access: `oc exec curl-test -n hello-direct -- curl -I http://hello-service.hello-direct.svc.cluster.local` (Should be 403).
4. Get token and test:
```bash
TOKEN=$(oc exec curl-test -n hello-direct -- curl -d "client_id=hello-client" -d "username=workshop-user" -d "password=Password123!" -d "grant_type=password" "http://hello-keycloak-service.keycloak.svc:8080/realms/hello-realm/protocol/openid-connect/token" | jq -r .access_token)

oc exec curl-test -n hello-direct -- curl -I -H "Authorization: Bearer $TOKEN" http://hello-service.hello-direct.svc.cluster.local
```

---

## 4. Tutorial 2: Transparent OIDC Redirection (Browser)

### 4.1 Deploy OAuth2-Proxy
```bash
oc create namespace hello-security
oc label namespace hello-security istio.io/dataplane-mode=ambient
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
  namespace: hello-security
spec:
  replicas: 1
  selector:
    matchLabels: { app: oauth2-proxy }
  template:
    metadata:
      labels: { app: oauth2-proxy }
    spec:
      containers:
      - name: oauth2-proxy
        image: quay.io/oauth2-proxy/oauth2-proxy:latest
        args:
        - --provider=oidc
        - --email-domain=*
        - --upstream=static://200
        - --http-address=0.0.0.0:4180
        - --oidc-issuer-url=https://keycloak.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com/realms/hello-realm
        - --client-id=hello-client
        - --redirect-url=https://hello-app-hello-direct.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com/oauth2/callback
        - --cookie-secret=SldUazVPY05Scm9Sck9SclpXNWtZWE5sYzNOMVpXRT0=
        env:
        - name: OAUTH2_PROXY_CLIENT_SECRET
          value: "zsQoTVnXQqqOhdwrqmiwICob5MgzwKFd"
---
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy
  namespace: hello-security
spec:
  ports: [{ name: http, port: 4180, targetPort: 4180 }]
  selector: { app: oauth2-proxy }
```

### 4.2 Edge Gateway and Routing


```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes: { namespaces: { from: All } }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: hello-app-edge
  namespace: istio-system
spec:
  host: hello-app-hello-direct.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com
  to: { kind: Service, name: istio-ingressgateway }
  port: { targetPort: http }
  tls: { termination: edge }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-combined-route
  namespace: hello-direct
spec:
  parentRefs: [{ name: istio-ingressgateway, namespace: istio-system }]
  hostnames: ["hello-app-hello-direct.apps.rosa.rosa-nj5p7.xldz.p3.openshiftapps.com"]
  rules:
  - matches: [{ path: { type: PathPrefix, value: /oauth2 } }]
    backendRefs: [{ name: oauth2-proxy, namespace: hello-security, port: 4180 }]
  - matches: [{ path: { type: PathPrefix, value: / } }]
    backendRefs: [{ name: hello-service, port: 80 }]
```

### 4.3 Configure Redirection Policy
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: force-oidc-login
  namespace: hello-direct
spec:
  targetRefs: [{ kind: Service, name: hello-service }]
  action: CUSTOM
  provider: { name: "oauth2-auth" }
  rules:
  - from: [{ source: { notRequestPrincipals: ["*"] } }]
```

---

## 5. Browser Testing
1. Open an **Incognito Tab**.
2. Visit `https://hello-app-hello-direct.apps.rosa...`.
3. You will be redirected to **Keycloak**. 
4. Login with `workshop-user` / `Password123!`.
5. After the callback, you will see the **Bitnami Nginx** welcome page.
