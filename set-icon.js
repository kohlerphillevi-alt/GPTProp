// electron-builder "afterPack": setzt das GPTProp-Icon in die EXE
// (signAndEditExecutable ist aus, sonst bliebe das Electron-Standardsymbol)
const fs = require('fs');
const path = require('path');

exports.default = async function setIcon(context) {
  if (context.electronPlatformName !== 'win32') return;
  const ResEdit = require('resedit');
  const { NtExecutable, NtExecutableResource } = require('pe-library');
  const exePath = path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.exe`);
  const exe = NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true });
  const res = NtExecutableResource.from(exe);
  const ico = ResEdit.Data.IconFile.from(fs.readFileSync(path.join(__dirname, 'icon.ico')));
  const group = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries)[0];
  ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
    res.entries, group ? group.id : 1, group ? group.lang : 1033, ico.icons.map((i) => i.data));
  res.outputResource(exe);
  fs.writeFileSync(exePath, Buffer.from(exe.generate()));
  console.log('  • GPTProp-Icon in die EXE geschrieben');
};
