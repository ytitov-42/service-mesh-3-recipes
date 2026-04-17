This guide describes how to configure **Red Hat OpenShift Service Mesh 3 (Ambient Mode)** to validate JWTs from multiple OIDC providers simultaneously (e.g., a Global Keycloak and Google Identity). This setup is native, highly stable, and designed for ROSA HCP environments.

In this scenario, we use the **Native RequestAuthentication** for validation and a single **EnvoyFilter** for the primary browser redirect.

-----

## 1\. Global Identity Configuration

Before cluster setup, ensure you have the following details from your providers:

  * Provider A (Keycloak):
      * Issuer: [https://sso.your-company.com/realms/global](https://www.google.com/url?sa=E&source=gmail&q=https://sso.your-company.com/realms/global)
      * JWKS URI: [https://sso.your-company.com/realms/global/protocol/openid-connect/certs](https://www.google.com/url?sa=E&source=gmail&q=https://sso.your-company.com/realms/global/protocol/openid-connect/certs)
  * Provider B (Google/External):
      * Issuer: [https://accounts.google.com](https://accounts.google.com)
      * JWKS URI: [https://www.googleapis.com/oauth2/v3/certs](https://www.google.com/url?sa=E&source=gmail&q=https://www.googleapis.com/oauth2/v3/certs)

-----

## 2\. Cluster Initialization

Repeat these steps for each ROSA cluster.

### 2.1 Initialize Control Plane

Install the Mesh in Ambient mode using the Sail Operator.

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.24.1
  profile: ambient
```

### 2.2 Define Egress for Both Providers

Istio must be allowed to exit the cluster to fetch signing keys (JWKS) from both providers.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: multi-provider-egress
  namespace: istio-system
spec:
  hosts:
  - sso.your-company.com
  - www.googleapis.com
  - accounts.google.com
  location: MESH_EXTERNAL
  ports:
  - number: 443
    name: https
    protocol: TLS
  resolution: DNS
```

-----

## 3\. Native Multi-Provider JWT Validation

This resource tells the Ingress Gateway and Waypoints how to verify tokens from different sources.

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: multi-jwt-verify
  namespace: istio-system # Apply globally to the Ingress Gateway
spec:
  jwtRules:
  - issuer: "https://sso.your-company.com/realms/global"
    jwksUri: "https://sso.your-company.com/realms/global/protocol/openid-connect/certs"
    forwardOriginalToken: true
  - issuer: "https://accounts.google.com"
    jwksUri: "https://www.googleapis.com/oauth2/v3/certs"
    forwardOriginalToken: true
```

-----

## 4\. Browser Redirection with API Bypass

We use one primary OIDC provider (Keycloak) for the browser redirect logic. API calls with tokens from *any* provider in the list above will bypass this redirect.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: native-oidc-redirection
  namespace: istio-system
spec:
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
      listener:
        filterChain:
          filter:
            name: "envoy.filters.network.http_connection_manager"
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.oauth2
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.oauth2.v3.OAuth2
          config:
            token_endpoint:
              cluster: outbound|443||sso.your-company.com
              uri: https://sso.your-company.com/realms/global/protocol/openid-connect/token
              timeout: 5s
            authorization_endpoint: https://sso.your-company.com/realms/global/protocol/openid-connect/auth
            redirect_uri: "https://app-cluster-1.apps.rosa.example.com/oauth2/callback"
            redirect_path_matcher:
              path: { exact: "/oauth2/callback" }
            
            # BYPASS LOGIC: If a valid JWT from ANY provider is found, do not redirect
            pass_through_matcher:
              - name: "authorization"
                string_match: { prefix: "Bearer " }
                
            credentials:
              client_id: "rosa-global-client"
              token_secret: { name: oidc-client-secret }
              hmac_secret: { name: oidc-client-secret }
```

-----

## 5\. Global Authorization Policy

This policy ensures that even if a request bypasses the redirect, it is only allowed if it carries a valid principal from one of your trusted providers.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-any-trusted-provider
  namespace: hello-direct
spec:
  targetRefs: [{ kind: Service, name: hello-service }]
  action: ALLOW
  rules:
  - from:
    - source:
        # Allows tokens from Keycloak OR Google
        requestPrincipals: 
        - "https://sso.your-company.com/realms/global/*"
        - "https://accounts.google.com/*"
```

-----

## 6\. Verification and Debugging

### 6.1 Check Loaded Filter

```bash
export GATEWAY_POD=$(kubectl get pods -n istio-system -l istio.io/gateway-name=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')

istioctl proxy-config listener $GATEWAY_POD -n istio-system --port 80 -o json | grep -A 20 "envoy.filters.http.oauth2"
```

### 6.2 Test API with Provider A (Keycloak)

```bash
curl -H "Authorization: Bearer <KEYCLOAK_TOKEN>" https://app.cluster-1.rosa.example.com/api
# Expected: 200 OK
```

### 6.3 Test API with Provider B (Google)

```bash
curl -H "Authorization: Bearer <GOOGLE_TOKEN>" https://app.cluster-1.rosa.example.com/api
# Expected: 200 OK
```

### 6.4 Test Browser (Unauthenticated)

1.  Open Browser to [https://app.cluster-1.rosa.example.com](https://www.google.com/search?q=https://app.cluster-1.rosa.example.com)
2.  Expected: **302 Redirect** to Keycloak.

-----

## 7\. Summary Checklist

1.  Istio Ingress Gateway must have egress access to both JWKS URIs.
2.  The `RequestAuthentication` resource must list all issuers.
3.  The `AuthorizationPolicy` must explicitly allow `requestPrincipals` from all issuers.
4.  The `EnvoyFilter` `pass_through_matcher` ensures that requests already possessing a token from any provider do not get caught in the Keycloak redirect loop.
