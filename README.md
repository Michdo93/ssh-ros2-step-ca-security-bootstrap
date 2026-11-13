# SSH ROS 2 step-ca Security Bootstrap

An interactive Bash utility that scans an IPv4 range for SSH services and runs
[ros2-step-ca-security-bootstrap](https://github.com/Michdo93/ros2-step-ca-security-bootstrap) on the
selected devices one after another: SROS2 enclaves for the nodes of each device, identity
certificates from step-ca, signed permissions and the renewal timer. It works like the other SSH
tools: range → scan → confirm each device → user name → up to three login attempts.

What this tool adds on top of running the setup script by hand:

- the step-ca settings and the **provisioner password are asked once** for all devices,
- **one shared permissions CA** is created (or reused) and given to every device – required so that
  nodes on different hosts accept each other's permissions,
- one SSH login per device (an SSH master connection carries the uploads and the interactive run).

Copying enclaves between hosts is not done – every device creates the enclaves of its own nodes.

## Requirements

- Local: Bash 4, OpenSSH client, `timeout`, `xargs`, `base64`, `openssl` (to create the permissions
  CA). With the `step` CLI installed locally the CA settings and the password are checked up front.
- Devices: everything the setup script needs – ROS 2 with SROS2 (Fast DDS), the step CLI
  ([step-cli-bootstrap](https://github.com/Michdo93/step-cli-bootstrap) /
  [ssh-step-cli-bootstrap-manager](https://github.com/Michdo93/ssh-step-cli-bootstrap-manager)),
  `openssl`, `python3`, Internet access, a user with `sudo`.
- The step-ca must be reachable from every device. How to get the URL, the fingerprint and the
  provisioner is described in the
  [setup script's README](https://github.com/Michdo93/ros2-step-ca-security-bootstrap#before-you-start-ca-url-fingerprint-provisioner).

## Run

```bash
chmod +x deploy-sros2.sh
./deploy-sros2.sh
```

1. **Settings (once):** step-ca URL, root fingerprint, JWK provisioner, provisioner password,
   least-privilege or permissive permissions, optional certificate lifetime (e.g. `720h`).
2. **Shared permissions CA:** directory, default `./sros2-permissions-ca`. If it holds
   `permissions_ca.cert.pem` and `permissions_ca.key.pem`, they are used; otherwise a new CA
   (EC P-256, 10 years) is created there. **Keep this directory** – every device added later
   needs the same CA.
3. **Range** and **scan** (32 parallel probes, no ping needed).
4. **Per device:** confirm, SSH user name (the user that runs the nodes), up to three login
   attempts. The password file and the permissions CA are uploaded to `~/.sros2-bootstrap-upload`
   (mode 600) and deleted after the run. The setup script then runs in your terminal:
   - start the nodes of **that device** without security (`ROS_SECURITY_ENABLE=false ros2 launch …`,
     e.g. in a second SSH session) and press Enter,
   - `ros2 node list` shows the whole ROS domain – answer *no* to "Do ALL these nodes run on THIS
     host?" and select only the nodes of that device,
   - the sudo password is asked for the renewal timer.

At the end the tool lists the successful and the failed devices.

## Options (environment)

| Variable | Default | Meaning |
|---|---|---|
| `PERM_CA_DIR` | `./sros2-permissions-ca` | default directory of the shared permissions CA |
| `SCRIPT_URL` | `setup_sros2.sh` of ros2-step-ca-security-bootstrap (`main`) | other setup script |
| `SSH_PORT` | `22` | SSH port for scan and login |
| `CONNECT_TIMEOUT` | `4` | seconds per connection attempt |
| `SCAN_PARALLEL` | `32` | parallel probes while scanning |

## Security notes

- The permissions CA key can sign permissions for any enclave – store `./sros2-permissions-ca`
  like any other CA key (mode 700/600, backup, not in a repository).
- The provisioner password is only kept in a temporary local file (deleted on exit) and in the
  upload directory on the device during the run.

## License

MIT License. Feel free to use and modify.
