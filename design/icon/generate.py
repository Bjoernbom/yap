#!/usr/bin/env python3
"""Generates the yap app icon from pixel grids, so it is reproducible from source.

    python3 design/icon/generate.py            # write App/Resources/Assets.xcassets
    python3 design/icon/generate.py --sheet    # also render design/icon/concepts.png
    python3 design/icon/generate.py --final <yap.app>   # final-<size>.png from a build
    python3 design/icon/generate.py --measure  # re-measure kernel.json (new macOS)

Needs Pillow, Xcode (actool) and swift. See README.md for the why.

How macOS 26 draws a classic AppIcon: it takes each full-bleed square image,
scales it into the rounded "body" and masks it. The body is smaller than the
image (1024 -> 824, 64 -> 52, 16 -> 14), and 16 pt on Retina uses the 32 px
image squeezed to 28 px. Pixel art drawn on the image grid goes soft. So each
design is drawn on the body's own pixel grid, and for the small images, whose
resampling kernel --measure records, the image is solved for: the one that
comes out closest to that grid after macOS resamples it.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
ASSETS = os.path.join(ROOT, 'App', 'Resources', 'Assets.xcassets')
FONT = os.path.join(ROOT, 'App', 'Resources', 'Fonts', 'PixelifySans.ttf')
SCRATCH = os.path.join(ROOT, 'build', 'icon')
KERNELS = os.path.join(HERE, 'kernel.json')

# The concept that ships. The others stay here so the sheet can be rebuilt.
CHOSEN = 'wave'

COLORS = {
	'.': (10, 10, 10),     # icon black, a hair above pure black so the edge light reads
	'k': (0, 0, 0),        # the notch itself
	'#': (245, 245, 245),  # ink
	'L': (200, 255, 61),   # signal lime, #C8FF3D
	'l': (95, 118, 34),    # dim lime: a quiet bar, lime at 45 % on black
}

SIZES = (16, 32, 64, 128, 256, 512, 1024)
# The point size and scale that show each small image on a Retina Mac. The
# 32 px image is also 32 pt @1x, but 16 pt @2x (the Accessibility list, Finder
# list view) wins. Bigger images are resampled too, but by then a half-pixel
# edge is invisible.
RETINA = {16: (16, 1), 32: (16, 2), 64: (32, 2), 128: (64, 2)}
ITERATIONS = 150

# The pixel "yap" from the menu bar wordmark (MenuBarIcon.swift).
GLYPHS = {
	'y': ['#..#', '#..#', '#..#', '#..#', '.###', '...#', '###.'],
	'a': ['.##.', '...#', '.###', '#..#', '.###', '....', '....'],
	'p': ['###.', '#..#', '#..#', '#..#', '###.', '#...', '#...'],
}


class Grid:
	def __init__(self, size, fill='.'):
		self.size = size
		self.cells = [[fill] * size for _ in range(size)]

	def rect(self, x, y, w, h, c):
		for row in range(y, y + h):
			for col in range(x, x + w):
				if 0 <= row < self.size and 0 <= col < self.size:
					self.cells[row][col] = c

	def bitmap(self, rows, x, y, c=None, scale=1):
		for r, line in enumerate(rows):
			for col, ch in enumerate(line):
				if ch != '.':
					self.rect(x + col * scale, y + r * scale, scale, scale, c or ch)

	def padded(self, pad):
		out = Grid(self.size + 2 * pad, self.cells[self.size // 2][0])
		for r in range(self.size):
			for col in range(self.size):
				out.cells[r + pad][col + pad] = self.cells[r][col]
		return out


def parse(rows):
	grid = Grid(len(rows))
	for r, line in enumerate(rows):
		assert len(line) == len(rows), f'row {r} is {len(line)} wide'
		grid.cells[r] = list(line)
	return grid


# Concepts. Each has a master grid (the body at 52 px and up) and a
# hand-tuned 14 x 14 grid for the 16 px image.

def cursor():
	"""A pixel "y" and a lime text cursor: talk, it types."""
	g = Grid(26)
	g.bitmap(GLYPHS['y'], 4, 2, '#', 3)
	g.rect(19, 2, 3, 15, 'L')
	small = parse([
		'..............',
		'..............',
		'..##..##..LL..',
		'..##..##..LL..',
		'..##..##..LL..',
		'..##..##..LL..',
		'..##..##..LL..',
		'...#####..LL..',
		'......##......',
		'......##......',
		'..#####.......',
		'..............',
		'..............',
		'..............',
	])
	return g, small


# Mirrored around the middle bar like the notch, uneven like real speech.
# The outer bars are quiet: one dim dot, like a silent bar in the notch.
WAVE_HEIGHTS = [1, 5, 3, 7, 3, 5, 1]


def wave():
	"""The notch's pixel waveform, lime dots on black."""
	g = Grid(26)
	for i, dots in enumerate(WAVE_HEIGHTS):
		color = 'l' if dots == 1 else 'L'
		for j in range(-(dots // 2), dots // 2 + 1):
			g.rect(3 + 3 * i, 12 + 3 * j, 2, 2, color)
	# At 16 pt macOS squeezes 8 image pixels into 7 screen pixels, and only
	# edges at 6-8, 13-15 and 20-22 (of the 28 px body) come out sharp; see
	# kernel.json. Dots with 1 px gaps smear there, so 16 pt gets three
	# solid bars with every edge on a sharp line.
	retina = Grid(28)
	retina.rect(6, 8, 2, 12, 'L')
	retina.rect(13, 5, 2, 18, 'L')
	retina.rect(20, 8, 2, 12, 'L')
	# Same idea at 16 pt @1x (14 px body, sharp edges only at 6-8).
	small = Grid(14)
	small.rect(2, 4, 2, 6, 'L')
	small.rect(6, 2, 2, 10, 'L')
	small.rect(10, 4, 2, 6, 'L')
	return g, small, retina


def notch():
	"""A black notch hanging from the top edge, waveform inside, on lime."""
	g = Grid(26, 'L')
	g.rect(4, 0, 18, 10, 'k')
	g.rect(5, 10, 16, 1, 'k')
	g.rect(7, 11, 12, 1, 'k')
	for i, dots in enumerate([1, 3, 1, 3, 1]):
		for j in range(-(dots // 2), dots // 2 + 1):
			g.rect(6 + 3 * i, 5 + 3 * j, 2, 2, 'L')
	small = parse([
		'..kkkkkkkkkk..',
		'..kkkkkkkkkk..',
		'..kkkLkkLkkk..',
		'..kkLLkkLLkk..',
		'..kkkLkkLkkk..',
		'..kkkkkkkkkk..',
		'...kkkkkkkk...',
		'..............',
		'..............',
		'..............',
		'..............',
		'..............',
		'..............',
		'..............',
	])
	for row in small.cells:
		for i, ch in enumerate(row):
			if ch == '.':
				row[i] = 'L'
	return g, small


def wordmark():
	"""The 0.4 icon, pixel-snapped: the "yap" wordmark over a lime dot line."""
	g = Grid(32)
	for i, ch in enumerate('yap'):
		g.bitmap(GLYPHS[ch], 2 + i * 10, 8, '#', 2)
	for i in range(9):
		g.rect(3 + 3 * i, 25, 2, 2, 'L')
	small = Grid(14)
	for i, ch in enumerate('yap'):
		small.bitmap(GLYPHS[ch], i * 5, 3, '#')
	return g, small


CONCEPTS = [
	('cursor', 'y + cursor', cursor),
	('wave', 'pixel waveform', wave),
	('notch', 'notch on lime', notch),
	('wordmark', '0.4 wordmark', wordmark),
]


def target(grid, body):
	"""What the body should look like, pixel for pixel: the grid sampled at
	body pixel centres. Grids are sized so each cell is a whole number of
	pixels at the sizes that have a kernel."""
	n = grid.size
	cells = [min(int((b + 0.5) * n / body), n - 1) for b in range(body)]
	return [[COLORS[grid.cells[gy][gx]] for gx in cells] for gy in cells]


def point_sampled(grid, size):
	n = grid.size
	img = Image.new('RGB', (size, size))
	px = img.load()
	cells = [min(int((i + 0.5) * n / size), n - 1) for i in range(size)]
	for y, gy in enumerate(cells):
		for x, gx in enumerate(cells):
			px[x, y] = COLORS[grid.cells[gy][gx]]
	return img


def load_kernels():
	if not os.path.exists(KERNELS):
		return {}
	with open(KERNELS) as f:
		return {int(k): v for k, v in json.load(f).items()}


def solve(grid, size, kernel):
	"""Finds the image that, once macOS resamples it into the body, comes
	closest to the pixel-exact target: bounded least squares per channel
	(FISTA), using the separable kernel measured by --measure."""
	body, offset = kernel['body'], kernel['offset']
	rows = {int(k) - offset: [(i, w) for i, w in taps] for k, taps in kernel['rows'].items()}
	want = target(grid, body)
	start = point_sampled(grid, size)
	outs = sorted(rows)

	def forward(src):
		# K · src · Kᵀ, for the body pixels the kernel covers.
		half = {b: [sum(w * src[i][j] for i, w in rows[b]) for j in range(size)] for b in outs}
		return {b: {c: sum(w * half[b][i] for i, w in rows[c]) for c in outs} for b in outs}

	def backward(res):
		# Kᵀ · res · K
		half = {b: [0.0] * size for b in outs}
		for b in outs:
			line = half[b]
			for c in outs:
				r = res[b][c]
				for i, w in rows[c]:
					line[i] += w * r
		grad = [[0.0] * size for _ in range(size)]
		for b in outs:
			for i, w in rows[b]:
				line = grad[i]
				for j, v in enumerate(half[b]):
					line[j] += w * v
		return grad

	channels = []
	for ch in range(3):
		src = [[start.getpixel((x, y))[ch] / 255 for x in range(size)] for y in range(size)]
		goal = {b: {c: want[b][c][ch] / 255 for c in outs} for b in outs}
		prev = src
		guess = [line[:] for line in src]
		t = 1.0
		for _ in range(ITERATIONS):
			out = forward(guess)
			grad = backward({b: {c: out[b][c] - goal[b][c] for c in outs} for b in outs})
			nxt = [[min(1.0, max(0.0, guess[y][x] - grad[y][x])) for x in range(size)] for y in range(size)]
			t2 = (1 + (1 + 4 * t * t) ** 0.5) / 2
			guess = [[nxt[y][x] + (t - 1) / t2 * (nxt[y][x] - prev[y][x]) for x in range(size)] for y in range(size)]
			prev, t = nxt, t2
		channels.append(prev)
	img = Image.new('RGB', (size, size))
	px = img.load()
	for y in range(size):
		for x in range(size):
			px[x, y] = tuple(round(channels[ch][y][x] * 255) for ch in range(3))
	return img


def grids_for(make):
	"""Image size -> the grid drawn into it. Concepts return a master grid,
	a 14 px grid for 16 pt @1x and optionally a 28 px grid for 16 pt @2x."""
	master, small, *rest = make()
	grids = {size: master for size in SIZES}
	grids[16] = small
	if rest:
		grids[32] = rest[0]
	elif master.size == 26:
		# Body 28 = the 26 master plus one cell of margin: 1:1 pixels.
		grids[32] = master.padded(1)
	return grids


def images_for(make):
	kernels = load_kernels()
	out = {}
	for size, grid in grids_for(make).items():
		out[size] = solve(grid, size, kernels[size]) if size in kernels else point_sampled(grid, size)
	return out


def measure():
	"""Measures how IconServices resamples each small image into its body:
	renders combs of lime columns and records, per screen pixel, which image
	columns feed it and how much. Writes kernel.json."""
	period = 8
	work = tempfile.mkdtemp(dir=os.makedirs(SCRATCH, exist_ok=True) or SCRATCH)
	combs = {}
	for phase in range(period):
		images = {}
		for size in SIZES:
			im = Image.new('RGB', (size, size), COLORS['.'])
			for x in range(phase, size, period):
				ImageDraw.Draw(im).line([(x, 0), (x, size - 1)], fill=COLORS['L'])
			images[size] = im
		app = preview_app(f'comb{phase}', images, work)
		render_app(app, f'comb{phase}', work, (16, 32, 64))
		for size, (pt, scale) in RETINA.items():
			name = f'comb{phase}-{pt}{"@2x" if scale == 2 else ""}.png'
			im = Image.open(os.path.join(work, name)).convert('RGB')
			n = im.size[0]
			combs[(size, phase)] = [im.getpixel((x, n // 2))[1] for x in range(n)]
	kernels = {}
	for size in RETINA:
		# The body is wherever some comb shows up. Its outer pixels carry the
		# rim light, so they are left out.
		lit = [x for x in range(len(combs[(size, 0)])) if any(combs[(size, p)][x] > 60 for p in range(period))]
		offset, body = lit[0], lit[-1] - lit[0] + 1
		scale = body / size
		rim = max(1, body // 50)
		rows = {}
		for k in range(offset + rim, offset + body - rim):
			centre = (k + 0.5 - offset) / scale - 0.5
			taps = []
			for phase in range(period):
				i = phase + period * round((centre - phase) / period)
				weight = (combs[(size, phase)][k] - COLORS['.'][1]) / (COLORS['L'][1] - COLORS['.'][1])
				if 0 <= i < size and abs(i - centre) <= 3 and weight > 0.01:
					taps.append([i, weight])
			total = sum(w for _, w in taps)
			rows[k] = [[i, round(w / total, 4)] for i, w in sorted(taps)]
		kernels[size] = {'offset': offset, 'body': body, 'rows': rows}
	with open(KERNELS, 'w') as f:
		json.dump(kernels, f, separators=(',', ':'))
		f.write('\n')
	shutil.rmtree(work)
	print(f'wrote {os.path.relpath(KERNELS, ROOT)}')


def write_iconset(images, directory):
	os.makedirs(directory, exist_ok=True)
	entries = []
	for point in [16, 32, 128, 256, 512]:
		for scale in [1, 2]:
			name = f'icon_{point}x{point}{"@2x" if scale == 2 else ""}.png'
			images[point * scale].save(os.path.join(directory, name))
			entries.append({'filename': name, 'idiom': 'mac', 'scale': f'{scale}x', 'size': f'{point}x{point}'})
	with open(os.path.join(directory, 'Contents.json'), 'w') as f:
		json.dump({'images': entries, 'info': {'author': 'xcode', 'version': 1}}, f, indent=2)
		f.write('\n')


def write_catalog(images, catalog):
	os.makedirs(catalog, exist_ok=True)
	with open(os.path.join(catalog, 'Contents.json'), 'w') as f:
		json.dump({'info': {'author': 'xcode', 'version': 1}}, f, indent=2)
		f.write('\n')
	write_iconset(images, os.path.join(catalog, 'AppIcon.appiconset'))


def stub_executable():
	path = os.path.join(SCRATCH, 'stub')
	if not os.path.exists(path):
		os.makedirs(SCRATCH, exist_ok=True)
		source = os.path.join(SCRATCH, 'stub.swift')
		with open(source, 'w') as f:
			f.write('print("icon preview")\n')
		subprocess.run(['xcrun', 'swiftc', source, '-o', path], check=True)
	return path


def renderer():
	path = os.path.join(SCRATCH, 'render-icon')
	source = os.path.join(HERE, 'render-icon.swift')
	if not os.path.exists(path) or os.path.getmtime(path) < os.path.getmtime(source):
		os.makedirs(SCRATCH, exist_ok=True)
		subprocess.run(['xcrun', 'swiftc', '-O', source, '-o', path], check=True)
	return path


def render_app(app, prefix, out_dir, sizes=(16, 32, 128, 512)):
	subprocess.run([renderer(), app, out_dir, prefix, *map(str, sizes)], check=True)


def preview_app(name, images, work):
	"""A throwaway app bundle carrying the compiled icon, so IconServices
	renders it exactly as it would render yap.app. A fresh path and bundle id
	every run keep the icon cache out of the way."""
	catalog = os.path.join(work, f'{name}.xcassets')
	write_catalog(images, catalog)
	app = os.path.join(work, f'{name}-{uuid.uuid4().hex[:8]}.app')
	resources = os.path.join(app, 'Contents', 'Resources')
	os.makedirs(resources)
	os.makedirs(os.path.join(app, 'Contents', 'MacOS'))
	subprocess.run([
		'xcrun', 'actool', catalog, '--compile', resources, '--platform', 'macosx',
		'--minimum-deployment-target', '26.0', '--app-icon', 'AppIcon',
		'--output-partial-info-plist', os.path.join(work, f'{name}.plist'),
	], check=True, stdout=subprocess.DEVNULL)
	shutil.copy(stub_executable(), os.path.join(app, 'Contents', 'MacOS', 'stub'))
	with open(os.path.join(app, 'Contents', 'Info.plist'), 'w') as f:
		f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>stub</string>
<key>CFBundleIdentifier</key><string>com.bjornbom.yap.iconpreview.{os.path.basename(app)[:-4]}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
</dict></plist>
''')
	subprocess.run(['codesign', '-s', '-', '--force', app], check=True, stderr=subprocess.DEVNULL)
	subprocess.run([
		'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
		'-f', app,
	], check=True)
	return app


LIGHT = (236, 236, 238)
DARK = (30, 30, 32)


def font(size):
	return ImageFont.truetype(FONT, size)


def sheet(renders, path):
	"""One row per concept; light and dark halves. Each half: 1024 (shown at
	half size), 128, 32, 16 at real pixels, then 32 and 16 pt @2x
	magnified with nearest neighbour so the pixel grid can be judged."""
	pad, zoom = 32, 128
	half = pad + 512 + pad + 128 + pad + 32 + pad + 16 + pad + zoom + pad + zoom + pad
	row_h = 512 + 2 * pad + 40
	width = 2 * half
	img = Image.new('RGB', (width, 110 + row_h * len(renders)), DARK)
	draw = ImageDraw.Draw(img)
	draw.rectangle([0, 0, half - 1, img.height], fill=LIGHT)
	draw.text((pad, 30), 'yap app icon concepts', font=font(40), fill=(10, 10, 10))
	draw.text((half + pad, 30), '1024 · 128 · 32 · 16 · 32pt@2x · 16pt@2x (zoomed 2x / 4x)', font=font(24), fill=(200, 200, 200))
	for r, (label, files) in enumerate(renders):
		top = 110 + r * row_h
		for side, bg in enumerate([LIGHT, DARK]):
			ink = (10, 10, 10) if side == 0 else (240, 240, 240)
			x = side * half + pad
			draw.text((x, top), label, font=font(28), fill=ink)
			y = top + 40
			big = Image.open(files[(512, 2)]).convert('RGBA').resize((512, 512), Image.LANCZOS)
			img.paste(big, (x, y), big)
			x += 512 + pad
			for size in (128, 32, 16):
				icon = Image.open(files[(size, 1)]).convert('RGBA')
				img.paste(icon, (x, y + 512 - 128 - (size - 128) // 2 - 64), icon)
				x += size + pad
			for size in (32, 16):
				icon = Image.open(files[(size, 2)]).convert('RGBA')
				icon = icon.resize((zoom, zoom), Image.NEAREST)
				img.paste(icon, (x, y + 512 - 128 - 64 - 32), icon)
				x += zoom + pad
	img.save(path, optimize=True)


def main():
	if '--measure' in sys.argv:
		measure()

	images = images_for(dict((n, m) for n, _, m in CONCEPTS)[CHOSEN])
	write_catalog(images, ASSETS)
	print(f'wrote {CHOSEN} to {os.path.relpath(ASSETS, ROOT)}')

	if '--sheet' in sys.argv:
		work = tempfile.mkdtemp(dir=os.makedirs(SCRATCH, exist_ok=True) or SCRATCH)
		renders = []
		for name, label, make in CONCEPTS:
			app = preview_app(name, images_for(make), work)
			render_app(app, name, work)
			files = {(s, k): os.path.join(work, f'{name}-{s}{"@2x" if k == 2 else ""}.png') for s in (16, 32, 128, 512) for k in (1, 2)}
			renders.append((label + ('  (shipped)' if name == CHOSEN else ''), files))
		sheet(renders, os.path.join(HERE, 'concepts.png'))
		shutil.rmtree(work)
		print('wrote design/icon/concepts.png')

	if '--final' in sys.argv:
		app = sys.argv[sys.argv.index('--final') + 1]
		work = tempfile.mkdtemp(dir=os.makedirs(SCRATCH, exist_ok=True) or SCRATCH)
		render_app(app, 'final', work, (16, 32, 128, 512))
		for size in (16, 32, 128, 512):
			for suffix in ('', '@2x'):
				shutil.copy(os.path.join(work, f'final-{size}{suffix}.png'), os.path.join(HERE, f'final-{size}{suffix}.png'))
		shutil.rmtree(work)
		print('wrote design/icon/final-*.png')


if __name__ == '__main__':
	main()
