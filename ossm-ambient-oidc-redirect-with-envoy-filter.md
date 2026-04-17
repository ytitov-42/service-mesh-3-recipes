This is the complete technical guide for setting up native OIDC redirection with API bypass on **ROSA HCP** using **Service Mesh 3 (Ambient Mode)**. This version is optimized for GitHub Markdown and contains no icons or non-text characters.
# Summary of AWS/ROSA Flow
- **AWS NLB** receives traffic.
- **OpenShift Router** terminates TLS and forwards to Istio Ingress Gateway.
- **Envoy Filter** inspects headers.
- **If Browser**: Redirects via the internet to your Global Keycloak.
- **If API**: Passes the request into the Mesh.
- **Waypoint Proxy** enforces the AuthorizationPolicy to ensure the API call has a valid token.

## Prereqs:
- **Security Groups**: Ensure your ROSA worker node security groups allow Outbound 443 to the internet (or your NAT Gateway) so the Ingress Gateway can reach the token_endpoint.
- **Register Clients**: In Keycloak, create a client (e.g., rosa-global-client):
- **Whitelist Redirects**: Add the callback URLs for both clusters to the "Valid Redirect URIs":

   * https://app.cluster-1.rosa.aws.../oauth2/callback
   * https://app.cluster-2.rosa.aws.../oauth2/callback

- **Client Secret**: Note the Client Secret; you will need to sync this across both ROSA clusters.
- **AWS Egress (NAT Gateway): **
Since the Ingress Gateway is initiating a connection to the internet to talk to the OIDC provider, your ROSA worker nodes must have a route to a NAT Gateway (if they are in private subnets) or an Internet Gateway.

-----

## 1\. Global Identity Setup (External)

Configure your OIDC provider (Keycloak, Okta, etc.) with the following parameters:

  * Client ID: rosa-global-client
  * Client Secret: Save the generated secret for the next steps.
  * Valid Redirect URIs:
      * [https://app-cluster-1.apps.rosa.example.com/oauth2/callback](https://www.google.com/url?sa=E&source=gmail&q=https://app-cluster-1.apps.rosa.example.com/oauth2/callback)
      * [https://app-cluster-2.apps.rosa.example.com/oauth2/callback](https://www.google.com/search?q=https://app-cluster-2.apps.rosa.example.com/oauth2/callback)

-----

## 2\. Cluster Prerequisites

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

### 2.2 Define the Global Exit (Egress)

Allow Istio to communicate with your external provider.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: global-sso-egress
  namespace: istio-system
spec:
  hosts:
  - sso.your-company.com
  location: MESH_EXTERNAL
  ports:
  - number: 443
    name: https
    protocol: TLS
  resolution: DNS
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: global-sso-tls
  namespace: istio-system
spec:
  host: sso.your-company.com
  trafficPolicy:
    tls:
      mode: SIMPLE
      sni: sso.your-company.com
```

### 2.3 Store Credentials

Create a secret in the istio-system namespace to store your OIDC client secret.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: oidc-client-secret
  namespace: istio-system
stringData:
  client-secret: "YOUR_GLOBAL_CLIENT_SECRET"
```

-----

## 3\. The Comprehensive Native Filter

The pass\_through\_matcher enables Envoy to differentiate between browser requests (which trigger a redirect) and API requests (which skip the redirect).

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: native-oidc-with-api-bypass
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
            # Replace the hostname below for each specific cluster
            redirect_uri: "https://app-cluster-1.apps.rosa.example.com/oauth2/callback"
            redirect_path_matcher:
              path: { exact: "/oauth2/callback" }
            
            # BYPASS LOGIC: Requests matching these headers will skip the OIDC redirect
            pass_through_matcher:
              - name: "authorization"
                string_match: { prefix: "Bearer " }
              - name: "x-requested-with"
                string_match: { exact: "XMLHttpRequest" }
              - name: "accept"
                string_match: { exact: "application/json" }
                
            credentials:
              client_id: "rosa-global-client"
              token_secret: { name: oidc-client-secret }
              hmac_secret: { name: oidc-client-secret }
```

-----

## 4\. Workload Security

Because API requests bypass the redirect, you must enforce JWT validation on the application workload to prevent unauthenticated access.

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-verify
  namespace: hello-direct
spec:
  targetRefs: [{ kind: Service, name: hello-service }]
  jwtRules:
  - issuer: "https://sso.your-company.com/realms/global"
    jwksUri: "https://sso.your-company.com/realms/global/protocol/openid-connect/certs"
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt-auth
  namespace: hello-direct
spec:
  targetRefs: [{ kind: Service, name: hello-service }]
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://sso.your-company.com/*"]
```

-----

## 5\. Gateway and Routing

### 5.1 Ingress Gateway

Deploy the Gateway resource to provision the Envoy-based ingress.

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
```

### 5.2 OpenShift Route

Map the AWS Load Balancer to the Istio Ingress Gateway.

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: app-edge
  namespace: istio-system
spec:
  host: app-cluster-1.apps.rosa.example.com
  to: { kind: Service, name: istio-ingressgateway }
  port: { targetPort: http }
  tls: { termination: edge }
```

-----

## 6\. Testing Instructions

| Client Type | Command / Header | Expected Behavior |
| :--- | :--- | :--- |
| Browser | No headers | 302 Redirect to Keycloak Login |
| REST API | -H "Accept: application/json" | 403 Forbidden (Redirect bypassed, JWT missing) |
| CLI / App | -H "Authorization: Bearer \<TOKEN\>" | 200 OK (Redirect bypassed, JWT valid) |


# Troubuleshooting
To verify that your "heavy-weight" native OIDC configuration is actually loaded and active inside the Ingress Gateway, you can use the Envoy **Config Dump**. 

This is the ultimate source of truth because it shows the final configuration after Istio has merged your `EnvoyFilter` into the proxy's memory.

### 1. Identify your Ingress Gateway Pod
First, find the exact name of your gateway pod in the `istio-system` namespace.

```bash
export GATEWAY_POD=$(kubectl get pods -n istio-system -l istio.io/gateway-name=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')
echo $GATEWAY_POD
```

### 2. Run the Debug Command
Use `istioctl` to pull the proxy configuration and grep for the `oauth2` filter.

```bash
istioctl proxy-config listener $GATEWAY_POD -n istio-system --port 80 -o json | grep -A 20 "envoy.filters.http.oauth2"
```

---

### 3. What to Look For in the Output
If the filter is correctly applied, you should see a JSON block similar to this:

```json
"name": "envoy.filters.http.oauth2",
"typed_config": {
    "@type": "type.googleapis.com/envoy.extensions.filters.http.oauth2.v3.OAuth2",
    "config": {
        "token_endpoint": {
            "cluster": "outbound|443||sso.your-company.com",
            "uri": "https://sso.your-company.com/..."
        },
        "authorization_endpoint": "https://sso.your-company.com/...",
        "pass_through_matcher": [
            { "name": "authorization" },
            { "name": "accept" }
        ]
    }
}
```

### 4. Troubleshooting Checklist if the Command returns nothing:
* **Filter Name:** Ensure the `name` in your `EnvoyFilter` matches `envoy.filters.http.oauth2` exactly.
* **Context Match:** Verify `context: GATEWAY` is set in your YAML. If it’s set to `SIDECAR_INBOUND`, the Ingress Gateway will ignore it.
* **Namespace:** The `EnvoyFilter` must be in the **same namespace** as the Gateway (usually `istio-system`) or in the root namespace.
* **Pilot Logs:** If the filter is rejected due to a syntax error (like a typo in the `typed_config`), `istiod` will log the error. Check it with:
    ```bash
    kubectl logs -l app=istiod -n istio-system | grep "EnvoyFilter"
    ```

### 5. Advanced: Enable Debug Logging
If the filter exists but isn't redirecting, you can temporarily tell the Ingress Gateway to log everything the OAuth2 filter is doing:

```bash
istioctl proxy-config log $GATEWAY_POD -n istio-system --level oauth2:debug
```
*Now, tail the logs and visit the app in your browser:*
```bash
kubectl logs -f $GATEWAY_POD -n istio-system
```
*You should see entries like `[oauth2] no cookie found, redirecting to authorization endpoint`.*

**Did the config dump show your filter as "Programmed" or is the output empty?**



# Networking: OpenShift Router as Bridge vs. BYO AWS NLB for Ingress Gateway 

In a production ROSA environment, **you have a choice**, but the way we configured it in the previous steps uses the **OpenShift Router as a bridge**. 

Here is exactly how those two pieces connect and why the "Independent NLB" doesn't necessarily bypass the Router.

---

### 1. The "Integrated" Path (How they talk)
When you use an **OpenShift Route** (as we did in step 5.2), you are telling the **OpenShift Ingress Controller** (the default HAProxy router) to handle the "public" side of the connection.

1.  **AWS NLB (Managed by OpenShift):** This is the "main" NLB that comes with every ROSA cluster. It sends traffic to the OpenShift Router (HAProxy).
2.  **OpenShift Router:** It terminates the SSL (using the cluster's wildcard cert).
3.  **The Hand-off:** Because we set `to: { kind: Service, name: istio-ingressgateway }`, the Router sends the decrypted traffic over the internal network to the **Istio Ingress Gateway pods**.
4.  **Envoy:** Now the traffic is "inside" the Mesh. Envoy runs the OIDC filter we wrote.

**Why do it this way?** It’s easier. You don't have to manage DNS or certificates for a second AWS Load Balancer; you just use the ROSA apps domain.

---

### 2. The "Independent" Path (BYO Load Balancer)
If you define the Istio Gateway as a `ServiceType: LoadBalancer`, Kubernetes **does** create a second, independent AWS NLB specifically for Envoy.

In this scenario:
1.  **Traffic completely bypasses the OpenShift Router.**
2.  **AWS NLB (Istio's NLB) -> Istio Ingress Gateway Pods.**
3.  **Envoy must handle its own TLS** (you have to upload certificates into the Mesh).

If you use this path, the "OpenShift Router terminates TLS" step from the previous flow is **removed**. Envoy becomes the absolute first point of contact in the cluster.



---

### 3. Comparing the L4/L7 Flow

| Feature | Via OpenShift Router (Our Guide) | Independent Istio Gateway |
| :--- | :--- | :--- |
| **External URL** | `*.apps.rosa.cluster.com` | Custom DNS (e.g., `api.mycompany.com`) |
| **TLS Termination** | OpenShift (Edge termination) | Envoy (Simple or Mutual TLS) |
| **AWS Resource** | Uses the existing ROSA NLB. | Provisions a **New** AWS NLB. |
| **Complexity** | Low (uses cluster defaults). | High (requires DNS/Cert management). |

---

### 4. How the "Native Filter" works in both cases
Regardless of whether the traffic comes from the OpenShift Router or a dedicated NLB, the **Envoy Filter** doesn't care. It simply sits at the "Entry Point" of the Mesh.

* If traffic comes from the **Router**: Envoy sees a request that has already been decrypted. It checks the headers and decides: "Redirect to Keycloak" or "Pass to App."
* If traffic comes from an **Independent NLB**: Envoy decrypts the traffic itself, then checks the headers and makes the same decision.

### Why the Waypoint Proxy is the Final Step
In Service Mesh 3 (Ambient), even after the Ingress Gateway (Envoy) says "This is a valid API call," it sends the traffic into the cluster. The **Waypoint Proxy** sits in front of your actual application pods. It is the final "Security Guard" that checks the `AuthorizationPolicy`. 



It acts as a **Zero Trust** fail-safe: if someone managed to bypass the Ingress Gateway, they would still be stopped by the Waypoint because they lack the proper JWT principal.


