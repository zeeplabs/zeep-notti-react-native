import { describe, expect, it } from '@jest/globals';
import fs from 'fs';
import os from 'os';
import path from 'path';
import type { AndroidConfig } from '@expo/config-plugins';
import {
  DEFAULT_NOTIFICATION_COLOR_META,
  DEFAULT_NOTIFICATION_ICON_META,
  copyNotificationIconAsync,
  resolveAndroidNotificationColor,
  setNotificationMetaData,
} from '../../plugin/src/withNotti';

type Manifest = AndroidConfig.Manifest.AndroidManifest;

function manifest(
  entries: { name: string; resource: string }[] = []
): Manifest {
  return {
    manifest: {
      $: { 'xmlns:android': 'http://schemas.android.com/apk/res/android' },
      application: [
        {
          '$': { 'android:name': '.MainApplication' },
          'meta-data': entries.map((m) => ({
            $: { 'android:name': m.name, 'android:resource': m.resource },
          })),
        },
      ],
    },
  } as Manifest;
}

function metaData(m: Manifest): Record<string, string | undefined> {
  const entries = m.manifest.application?.[0]?.['meta-data'] ?? [];
  return Object.fromEntries(
    entries.map((e) => [e.$['android:name'], e.$['android:resource']])
  );
}

describe('resolveAndroidNotificationColor', () => {
  it('accepts #RRGGBB and #AARRGGBB, normalized to upper case', () => {
    expect(resolveAndroidNotificationColor('#1a73e8')).toBe('#1A73E8');
    expect(resolveAndroidNotificationColor('#801A73E8')).toBe('#801A73E8');
  });

  it('returns undefined when the prop is not set', () => {
    expect(resolveAndroidNotificationColor(undefined)).toBeUndefined();
  });

  it.each(['1A73E8', '#FFF', 'blue', '#GGGGGG', ''])(
    'rejects %p so prebuild fails loudly',
    (color) => {
      expect(() => resolveAndroidNotificationColor(color)).toThrow(
        /androidNotificationColor/
      );
    }
  );
});

describe('setNotificationMetaData', () => {
  it('points FCM at the plugin icon and color', () => {
    const result = setNotificationMetaData(manifest(), {
      icon: true,
      color: true,
    });
    expect(metaData(result)).toEqual({
      [DEFAULT_NOTIFICATION_ICON_META]: '@drawable/notti_notification_icon',
      [DEFAULT_NOTIFICATION_COLOR_META]: '@color/notti_notification_color',
    });
  });

  it('removes its own entries when the props are dropped', () => {
    const written = setNotificationMetaData(manifest(), {
      icon: true,
      color: true,
    });
    const result = setNotificationMetaData(written, {
      icon: false,
      color: false,
    });
    expect(metaData(result)).toEqual({});
  });

  it('leaves an entry set by another plugin when the prop is not set', () => {
    const result = setNotificationMetaData(
      manifest([
        {
          name: DEFAULT_NOTIFICATION_ICON_META,
          resource: '@drawable/other_icon',
        },
      ]),
      { icon: false, color: false }
    );
    expect(metaData(result)).toEqual({
      [DEFAULT_NOTIFICATION_ICON_META]: '@drawable/other_icon',
    });
  });

  it('replaces an entry set by another plugin when the prop is set', () => {
    const result = setNotificationMetaData(
      manifest([
        {
          name: DEFAULT_NOTIFICATION_ICON_META,
          resource: '@drawable/other_icon',
        },
      ]),
      { icon: true, color: false }
    );
    expect(metaData(result)).toEqual({
      [DEFAULT_NOTIFICATION_ICON_META]: '@drawable/notti_notification_icon',
    });
  });
});

describe('copyNotificationIconAsync', () => {
  function tempProject(): { projectRoot: string; androidRoot: string } {
    const projectRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'notti-plugin-'));
    return { projectRoot, androidRoot: path.join(projectRoot, 'android') };
  }

  it('copies the PNG into drawable-xxxhdpi under the plugin resource name', async () => {
    const { projectRoot, androidRoot } = tempProject();
    fs.mkdirSync(path.join(projectRoot, 'assets'));
    fs.writeFileSync(path.join(projectRoot, 'assets/icon.png'), 'png-bytes');

    await copyNotificationIconAsync(
      projectRoot,
      androidRoot,
      './assets/icon.png'
    );

    const target = path.join(
      androidRoot,
      'app/src/main/res/drawable-xxxhdpi/notti_notification_icon.png'
    );
    expect(fs.readFileSync(target, 'utf8')).toBe('png-bytes');
  });

  it('fails when the file does not exist', async () => {
    const { projectRoot, androidRoot } = tempProject();
    await expect(
      copyNotificationIconAsync(projectRoot, androidRoot, 'missing.png')
    ).rejects.toThrow(/not found/);
  });

  it('fails when the file is not a PNG', async () => {
    const { projectRoot, androidRoot } = tempProject();
    fs.writeFileSync(path.join(projectRoot, 'icon.svg'), '<svg/>');
    await expect(
      copyNotificationIconAsync(projectRoot, androidRoot, 'icon.svg')
    ).rejects.toThrow(/\.png/);
  });
});
