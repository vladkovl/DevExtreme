#!/bin/bash -e

# Run inside https://hub.docker.com/r/devexpress/devextreme-build/

trap "echo 'Interrupted!' && kill -9 0" TERM INT

export DEVEXTREME_DOCKER_CI=true
export NUGET_PACKAGES=$PWD/dotnet_packages
export DOTNET_USE_POLLING_FILE_WATCHER=true

function run_lint {
    npm i eslint eslint-plugin-spellcheck eslint-plugin-qunit stylelint stylelint-config-standard npm-run-all babel-eslint
    npm run lint
}

function run_ts {
    target=./ts/dx.all.d.ts
    cp $target $target.current

    npm i
    npm update devextreme-internal-tools
    npm ls devextreme-internal-tools

    npm run update-ts

    if ! diff $target.current $target -U 5 > $target.diff; then
        echo "FAIL: $target is outdated:"
        cat $target.diff | sed "1,2d"
        exit 1
    else
        echo "TS is up-to-date"
    fi

    npx gulp ts-compilation-check ts-jquery-check npm-ts-modules-check
}

function run_test {
    export DEVEXTREME_QUNIT_CI=true

    local port=`node -e "console.log(require('./ports.json').qunit)"`
    local url="http://localhost:$port/run?notimers=true"
    local runner_pid
    local runner_result=0

    [ -n "$CONSTEL" ] && url="$url&constellation=$CONSTEL"
    [ -z "$JQUERY"  ] && url="$url&nojquery=true"

    if [ "$HEADLESS" != "true" ]; then
        Xvfb :99 -ac -screen 0 1200x600x24 &
        x11vnc -display :99 2>/dev/null &
    fi

    npm i
    npm run build

    dotnet ./testing/runner/bin/runner.dll --single-run & runner_pid=$!

    for i in {15..0}; do
        if [ -n "$runner_pid" ] && [ ! -e "/proc/$runner_pid" ]; then
            echo "Runner exited unexpectedly"
            exit 1
        fi

        httping -qsc1 "$url" && break

        if [ $i -eq 0 ]; then
            echo "Runner not reached"
            exit 1
        fi

        sleep 1
        echo "Waiting for runner..."
    done

    echo "URL: $url"

    case "$BROWSER" in

        "firefox")
            local firefox_args="-profile /firefox-profile $url"
            [ "$HEADLESS" == "true" ] && firefox_args="-headless $firefox_args"

            firefox --version
            firefox $firefox_args &
        ;;

        *)
            google-chrome-stable --version

            if [ "$HEADLESS" == "true" ]; then
                google-chrome-stable \
                    --no-sandbox \
                    --disable-dev-shm-usage \
                    --disable-gpu \
                    --user-data-dir=/tmp/chrome \
                    --headless \
                    --remote-debugging-address=0.0.0.0 \
                    --remote-debugging-port=9222 \
                    $url &>headless-chrome.log &
            else
                dbus-launch --exit-with-session google-chrome-stable \
                    --no-sandbox \
                    --disable-dev-shm-usage \
                    --disable-gpu \
                    --user-data-dir=/tmp/chrome \
                    --no-first-run \
                    --no-default-browser-check \
                    --disable-translate \
                    $url &
            fi
        ;;

    esac

    start_runner_watchdog $runner_pid
    wait $runner_pid || runner_result=1
    exit $runner_result
}

function run_test_themebuilder {
    dotnet build build/build-dotnet.sln
    npm i
    npm run build-themes
    npm run build-themebuilder-assets
    cd themebuilder
    npm i
    npm run test
}

function run_test_functional {
    npm i
    npm run build

    local args="--browsers chrome:headless";
    [ "$COMPONENT" ] && args="$args --componentFolder $COMPONENT";

    npm run test-functional -- $args
}

function start_runner_watchdog {
    local last_suite_time_file="$PWD/testing/LastSuiteTime.txt"
    local last_suite_time=unknown

    while true; do
        sleep 300

        if [ ! -f $last_suite_time_file ] || [ $(cat $last_suite_time_file) == $last_suite_time ]; then
            echo "Runner stalled"
            kill -9 $1
        else
            last_suite_time=$(cat $last_suite_time_file)
        fi
    done &
}

echo "node $(node -v), npm $(npm -v), dotnet $(dotnet --version)"

case "$TARGET" in
    "lint") run_lint ;;
    "ts") run_ts ;;
    "test") run_test ;;
    "test_themebuilder") run_test_themebuilder ;;
    "test_functional") run_test_functional ;;

    *)
        echo "Unknown target"
        exit 1
    ;;
esac
