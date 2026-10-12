import {setup, challenge} from "/.well-known/.git.gammaspectra.live/git/go-away/cmd/go-away/challenge/js-pow-sha256/static/load.mjs";


// from Xeact
const u = (url = "", params = {}) => {
    let result = new URL(url, window.location.href);
    Object.entries(params).forEach((kv) => {
        let [k, v] = kv;
        result.searchParams.set(k, v);
    });
    return result.toString();
};

(async () => {
    const status = document.getElementById('status');
    const title = document.getElementById('title');

    status.innerText = 'Starting challenge js-pow-sha256...';

    try {
        const info = await setup({
            Path: "/.well-known/.git.gammaspectra.live/git/go-away/cmd/go-away/challenge/js-pow-sha256",
            Parameters: "[123 34 100 105 102 102 105 99 117 108 116 121 34 58 34 49 50 34 125]"
        });

        if (info != "") {
            status.innerText = 'Calculating... ' + info
        } else {
            status.innerText = 'Calculating...';
        }
    } catch (err) {
        title.innerHTML = 'Oh no!';
        status.innerHTML = `Error: ${err.message}`;
        return
    }


    try {
        const t0 = Date.now();
        const { result, info } = await challenge();
        const t1 = Date.now();
        console.log({ result, info });

        title.innerHTML = 'Challenge success!';
        if (info != "") {
            status.innerHTML = `Done! Took ${t1 - t0}ms, ${info}`;
        } else {
            status.innerHTML = `Done! Took ${t1 - t0}ms`;
        }

        setTimeout(() => {
            const redir = window.location.href;
            window.location.href = u("/.well-known/.git.gammaspectra.live/git/go-away/cmd/go-away/challenge/js-pow-sha256/verify-challenge", {
                __goaway_token: result,
                __goaway_challenge: "js-pow-sha256",
                __goaway_redirect: redir,
                __goaway_id: "5c77285484e9afaafb7179dc2985f8b0",
                __goaway_elapsedTime: t1 - t0,
            });
        }, 500);
    } catch (err) {
        title.innerHTML = 'Oh no!';
        status.innerHTML = `Error: ${err.message}`;
    }
})();