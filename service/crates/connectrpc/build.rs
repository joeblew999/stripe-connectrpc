// Generate ConnectRPC server traits + clients from the stripe protos.
// Same wiring as google_maps feat/cloudflare-workers crates/connectrpc/build.rs.
fn main() {
    connectrpc_build::Config::new()
        .files(&[
            "proto/stripe/v1/checkout.proto",
            "proto/stripe/v1/catalog.proto",
            "proto/stripe/v1/billing.proto",
            "proto/stripe/v1/sigma.proto",
        ])
        .includes(&["proto"])
        .include_file("_connectrpc.rs")
        .compile()
        .expect("failed to compile stripe protos");
}
