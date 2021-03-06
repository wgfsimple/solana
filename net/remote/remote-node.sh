#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"/../..

set -x
deployMethod="$1"
nodeType="$2"
entrypointIp="$3"
numNodes="$4"
RUST_LOG="$5"
skipSetup="$6"
failOnValidatorBootupFailure="$7"
genesisOptions="$8"
set +x
export RUST_LOG

# Use a very large stake (relative to the default multinode-demo/ stake of 43)
# for the testnet validators setup by net/.  This make it less likely that
# low-staked ephemeral validator a random user may attach to testnet will cause
# trouble
#
# Ref: https://github.com/solana-labs/solana/issues/3798
stake=424243

missing() {
  echo "Error: $1 not specified"
  exit 1
}

[[ -n $deployMethod ]]  || missing deployMethod
[[ -n $nodeType ]]      || missing nodeType
[[ -n $entrypointIp ]]  || missing entrypointIp
[[ -n $numNodes ]]      || missing numNodes
[[ -n $skipSetup ]]     || missing skipSetup
[[ -n $failOnValidatorBootupFailure ]] || missing failOnValidatorBootupFailure

cat > deployConfig <<EOF
deployMethod="$deployMethod"
entrypointIp="$entrypointIp"
numNodes="$numNodes"
failOnValidatorBootupFailure=$failOnValidatorBootupFailure
genesisOptions="$genesisOptions"
EOF

source net/common.sh
loadConfigFile

case $deployMethod in
local|tar)
  PATH="$HOME"/.cargo/bin:"$PATH"
  export USE_INSTALL=1
  export SOLANA_METRICS_DISPLAY_HOSTNAME=1

  # Setup `/var/snap/solana/current` symlink so rsyncing the genesis
  # ledger works (reference: `net/scripts/install-rsync.sh`)
  sudo rm -rf /var/snap/solana/current
  sudo mkdir -p /var/snap/solana
  sudo ln -sT /home/solana/solana /var/snap/solana/current

  ./fetch-perf-libs.sh
  # shellcheck source=/dev/null
  source ./target/perf-libs/env.sh

  (
    sudo scripts/oom-monitor.sh
  ) > oom-monitor.log 2>&1 &
  echo $! > oom-monitor.pid
  scripts/net-stats.sh  > net-stats.log 2>&1 &
  echo $! > net-stats.pid

  case $nodeType in
  bootstrap-leader)
    if [[ -e /dev/nvidia0 && -x ~/.cargo/bin/solana-validator-cuda ]]; then
      echo Selecting solana-validator-cuda
      export SOLANA_CUDA=1
    fi
    set -x
    if [[ $skipSetup != true ]]; then
      args=(--bootstrap-leader-lamports "$stake")
      # shellcheck disable=SC2206 # Do not want to quote $genesisOptions
      args+=($genesisOptions)
      ./multinode-demo/setup.sh "${args[@]}"
    fi
    ./multinode-demo/drone.sh > drone.log 2>&1 &

    args=(
      --enable-rpc-exit
      --gossip-port "$entrypointIp":8001
    )

    ./multinode-demo/validator.sh --bootstrap-leader "${args[@]}" > fullnode.log 2>&1 &
    ;;
  validator|blockstreamer)
    net/scripts/rsync-retry.sh -vPrc "$entrypointIp":~/.cargo/bin/ ~/.cargo/bin/

    if [[ -e /dev/nvidia0 && -x ~/.cargo/bin/solana-validator-cuda ]]; then
      echo Selecting solana-validator-cuda
      export SOLANA_CUDA=1
    fi

    args=(
      "$entrypointIp":~/solana "$entrypointIp:8001"
      --gossip-port 8001
      --rpc-port 8899
    )
    if [[ $nodeType = blockstreamer ]]; then
      args+=(
        --blockstream /tmp/solana-blockstream.sock
        --no-voting
        --stake 0
      )
    else
      args+=(--stake "$stake")
      args+=(--enable-rpc-exit)
    fi

    set -x
    if [[ $skipSetup != true ]]; then
      ./multinode-demo/clear-config.sh
    fi

    if [[ $nodeType = blockstreamer ]]; then
      # Sneak the mint-keypair.json from the bootstrap leader and run another drone
      # with it on the blockstreamer node.  Typically the blockstreamer node has
      # a static IP/DNS name for hosting the blockexplorer web app, and is
      # a location that somebody would expect to be able to airdrop from
      scp "$entrypointIp":~/solana/config-local/mint-keypair.json config-local/
      ./multinode-demo/drone.sh > drone.log 2>&1 &

      export BLOCKEXPLORER_GEOIP_WHITELIST=$PWD/net/config/geoip.yml
      npm install @solana/blockexplorer@1
      npx solana-blockexplorer > blockexplorer.log 2>&1 &

      # Confirm the blockexplorer is accessible
      curl --head --retry 3 --retry-connrefused http://localhost:5000/

      # Redirect port 80 to port 5000
      sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
      sudo iptables -A INPUT -p tcp --dport 5000 -j ACCEPT
      sudo iptables -A PREROUTING -t nat -p tcp --dport 80 -j REDIRECT --to-port 5000

      # Confirm the blockexplorer is now globally accessible
      curl --head "$(curl ifconfig.io)"
    fi

    ./multinode-demo/validator.sh "${args[@]}" > fullnode.log 2>&1 &
    ;;
  *)
    echo "Error: unknown node type: $nodeType"
    exit 1
    ;;
  esac
  disown
  ;;
*)
  echo "Unknown deployment method: $deployMethod"
  exit 1
esac
