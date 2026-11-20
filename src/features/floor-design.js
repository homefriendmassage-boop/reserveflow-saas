export const decorTypes = [
  ['label', 'ข้อความอิสระ'], ['stage', '🎤 เวที'], ['door', '🚪 ประตู'],
  ['restroom', '🚻 ห้องน้ำ'], ['entrance', '➡️ ทางเข้า'], ['exit', '⬅️ ทางออก'], ['wall', '▰ ผนัง']
];

export const bounded = (value, fallback, min, max = Infinity) =>
  Math.max(min, Math.min(max, Number.isFinite(Number(value)) && value != null ? Number(value) : fallback));

export function floorGeometry(item = {}, index = 0) {
  return {
    x: bounded(item.x, 17 + (index % 3) * 33, 0, 100),
    y: bounded(item.y, 20 + Math.floor(index / 3) * 14, 0, 100),
    w: bounded(item.w, 84, 1),
    h: bounded(item.h, 72, 1)
  };
}

export function legacyFloor(category, storage = localStorage) {
  try {
    const config = JSON.parse(storage.getItem('reserveflow_config_v2'));
    if (!Array.isArray(config?.categories)) return null;
    const source = config.categories.find(row => row.template === category.template && row.id === category.code)
      || config.categories.find(row => row.template === category.template && row.name === category.name);
    if (!source || !Array.isArray(config.resources?.[source.id])) return null;
    const id = source.id;
    const size = config.layoutSizes?.[id];
    return {
      width: Math.round(bounded(size?.width, 960, 1)),
      height: Math.round(bounded(size?.height, 540, 1)),
      background: config.layoutImages?.[id] || null,
      decorations: (config.layoutDecor?.[id] || []).map(block => ({
        type: String(block.type || 'label'),
        label: String(block.label || 'ข้อความอิสระ').slice(0, 80),
        x: bounded(block.x, 50, 0, 100), y: bounded(block.y, 50, 0, 100),
        w: bounded(block.w, 130, 1), h: bounded(block.h, 58, 1)
      })),
      items: config.resources[id].map((item, index) => ({
        code: String(item.id), name: String(item.name || item.id).slice(0, 100),
        capacity: Math.round(bounded(item.capacity, category.template === 'table' ? 4 : 1, 1, 100)),
        ...floorGeometry(item, index)
      }))
    };
  } catch {
    return null;
  }
}

export function templatePositions(items, template) {
  const count = items.length;
  return items.map((item, index) => {
    const geometry = floorGeometry(item.display, index);
    if (template === 'u' || template === 'circle') {
      const t = count === 1 ? .5 : index / (count - 1);
      if (template === 'circle') {
        const angle = Math.PI * (1 + t);
        geometry.x = 50 + 34 * Math.cos(angle);
        geometry.y = 57 + 33 * Math.sin(angle);
      } else if (t < .33) {
        geometry.x = 16;
        geometry.y = 20 + t / .33 * 60;
      } else if (t < .67) {
        geometry.x = 16 + (t - .33) / .34 * 68;
        geometry.y = 80;
      } else {
        geometry.x = 84;
        geometry.y = 80 - (t - .67) / .33 * 60;
      }
    } else {
      const vertical = template === 'columns';
      const stride = template === 'grid' ? Math.ceil(Math.sqrt(count * 1.5)) : Math.min(count, 4);
      const across = Math.ceil(count / stride);
      const a = (index % stride + 1) * 100 / (stride + 1);
      const b = (Math.floor(index / stride) + 1) * 100 / (across + 1);
      [geometry.x, geometry.y] = vertical ? [b, a] : [a, b];
    }
    return { code: item.code, ...floorGeometry(geometry, index) };
  });
}

export function sampleTableFloor(items, decorations) {
  const sample = [
    [19, 25, 2], [50, 30, 4], [81, 25, 4],
    [19, 62, 6], [50, 63, 6], [81, 62, 8]
  ];
  const usedNames = new Set(items.map(row => row.name.trim().toLowerCase()));
  return {
    width: 960, height: 540,
    decorations: decorations.length ? decorations : [
      { type: 'label', label: 'เคาน์เตอร์ / จุดบริการ', x: 50, y: 8, w: 280, h: 40 },
      { type: 'entrance', label: 'ทางเข้า', x: 50, y: 92, w: 140, h: 40 }
    ],
    items: sample.map(([x, y, capacity], index) => {
      const code = 'T0' + (index + 1);
      const existing = items.find(row => row.code === code);
      const geometry = { ...floorGeometry(existing?.display), x, y };
      if (existing) return { code, ...geometry };
      const base = 'โต๊ะ ' + code;
      let name = base;
      let suffix = 2;
      while (usedNames.has(name.toLowerCase())) name = base + ' (' + suffix++ + ')';
      usedNames.add(name.toLowerCase());
      return { code, name, capacity, ...geometry };
    })
  };
}
