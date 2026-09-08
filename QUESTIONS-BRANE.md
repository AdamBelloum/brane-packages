## Highest-priority questions: remote execution and policy routing

These address the current blocker in your deployment: a workflow constrained to `client-node-2` is checked by `client-node-3`.

1. **How does the central driver select a worker/checker for a task with a location constraint?**  
   - What is the authoritative source for the mapping between a BraneScript location name such as `client-node-2` and a worker’s checker?
   - Which configuration files and fields are involved?

2. **What does `#[on("client-node-2")]` guarantee in the current Brane version?**  
   - Does it constrain planning only, execution only, or both?
   - Can the planner select another domain despite that annotation, and under which conditions?

3. **Why might the driver request `client-node-3` when the workflow specifies `client-node-2`?**  
   Bring your observed evidence: the accepted syntax, the requested location, and the denial from the policy checker on `client-node-3`.

4. **How can we inspect the planner’s and driver’s location-selection decision?**  
   - Which logs, log levels, commands, or APIs show:
     - requested location;
     - candidate locations;
     - chosen registry/checker;
     - reason for fallback or selection?

5. **Is a location label meant to identify a domain, a registry, a checker, a node, or a logical capability?**  
   This distinction is crucial for correctly naming your worker domains and workflow constraints.

6. **Is an explicit location-to-worker mapping required in the central `node.yml` or another configuration?**  
   - If so, can you provide a minimal working two-worker example?
   - Is there a required naming relation between central and worker configuration?

7. **What is the expected behaviour when the requested domain has no active policy?**  
   - Should planning fail before dispatch?
   - Or is a checker-side denial after dispatch the intended design?

---

## Policy-management questions

8. **What is the supported operational interface for policy management in the pinned Brane version?**  
   - Confirm the exact supported forms of `branectl policies add`, `list`, and `activate`.
   - Are policy-manager API endpoints on the checker intended for administrators, or only for internal services?

9. **What exactly is policy scope?**  
   - Is a policy activated per checker, worker domain, registry, or central instance?
   - Must an otherwise identical policy be installed separately on every worker domain?

10. **What claims and permissions should a policy-manager JWT contain?**  
    - Required claims such as `kid`, subject/username, issue and expiry times.
    - Expected signing algorithm and key-distribution model.
    - How should tokens be rotated or revoked?

11. **What is the supported way to diagnose a policy denial?**  
    - Can we obtain the evaluated rule, policy version, requester identity, operation, and target domain?
    - Is there a structured audit log suitable for an administrator-facing health or evidence report?

12. **What is the recommended baseline policy for controlled integration testing?**  
    - For example, a narrowly scoped policy that permits only a test user, a specific package, and a specified worker domain.
    - How should this differ from a permissive development policy?

---

## Certificates, identity, and trust questions

13. **What is the intended certificate and identity lifecycle for Brane users?**  
    - Is a per-user client certificate the expected long-term model?
    - Which identity attributes are derived from the certificate versus user-supplied workflow labels?

14. **Is a PEM identity bundle containing certificate and private key an officially supported input to `brane certs add`?**  
    Your tested CLI accepts the CA certificate plus `client-id.pem`, without a separate key argument. Ask whether this is stable API behaviour or version-specific convenience.

15. **What must be shared across central and worker domains?**  
    - Which CA certificates need cross-domain trust?
    - Which certificates must remain local to a domain?
    - Are there constraints on CA rotation without invalidating active identities?

16. **How should certificate rotation be performed without disrupting running domains or existing users?**  
    This matters because server-certificate generation in your pinned CLI is non-idempotent and creates a new CA on every invocation.

17. **What is the intended relation between a workflow submitter’s identity and policy evaluation?**  
    - Does the policy engine receive the submitting user identity end-to-end?
    - Can a user-controlled display label ever affect authorization?  
    The desired answer should be “no”; authorization should use authenticated identity, not a chosen label.

---

## Package and architecture questions

18. **What is the official package compatibility model across CPU architectures?**  
    You develop on Apple Silicon and deploy to x86_64 workers.
    - Is building packages for `linux/amd64` the supported approach?
    - Are multi-architecture package images supported or recommended?
    - Where is target architecture declared and validated?

---

## Deployment and operational questions

23. **What is the supported reference topology for one central node and multiple worker domains?**  
    Ask for an example that includes:
    - central API and driver;
    - worker registry, checker, and job services;
    - two or more domains;
    - policy services;
    - cross-domain certificate trust.

24. **Is running `brane-job` in the checker’s shared network namespace a supported topology?**  
    - Is localhost checker access from `brane-job` the intended approach?
    - What network-port exposure is required externally versus internally?

25. **Which ports, volumes, and service dependencies are stable operational contracts?**  
    Confirm the deployment assumptions around central API/driver, worker registry/checker, package storage, results, certificates, policy databases, and Docker socket access.

26. **What health checks should an operator run after deployment or upgrade?**  
    Request a recommended minimum checklist covering:
    - service liveness and readiness;
    - inter-service connectivity;
    - certificate validity and trust;
    - registry availability;
    - policy service readiness;
    - a minimal permitted remote workflow.

---

## Versioning and documentation questions

28. **Which Brane version and documentation revision should be treated as authoritative for this deployment?**  
    You use a pinned test CLI and deployment baseline. Ask:
    - whether the CLI, central services, and worker services must be byte-for-byte version aligned;
    - which version combinations are supported;
    - whether the current test build has known limitations around multi-domain planning.

29. **Which commands and configuration schemas are stable versus experimental?**  
    In particular:
    - `brane package build`, `package test`, `workflow run`;
    - `brane certs add`;
    - `branectl policies add/list/activate`;
    - BraneScript location annotations.

30. **Where should deployment operators look for definitive documentation when CLI behaviour and published docs differ?**  
    Ask for the preferred hierarchy: release notes, CLI `--help`, reference deployment, source code, issue tracker, or maintainer guidance.

---

## A useful closing question

31. **Could we jointly define a minimal, reproducible two-worker remote-execution test that must pass?**

Ask them to specify:

- one central node;
- two worker domains;
- one user identity;
- a policy allowing only one worker;
- a workflow explicitly constrained to that worker;
- expected planner, driver, checker, and job logs;
- expected result and failure modes.

This converts the current routing issue into a concrete upstream reproduction case and provides a durable regression test for your deployment.
