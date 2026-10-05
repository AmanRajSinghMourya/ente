const { Arch } = require("builder-util");
const { ensureVips } = require("./vips");

module.exports = async (context) => {
    await ensureVips(
        context.electronPlatformName,
        Arch[context.arch],
        context.packager.info.appDir,
    );
};
