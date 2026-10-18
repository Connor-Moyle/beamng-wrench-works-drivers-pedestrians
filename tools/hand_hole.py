"""Where a hand mesh's fingers curl round a bar: the biggest straight tube that runs clear through the curl (axis, a point on it, its free radius).
A steering wheel rim goes through that tube, so slrrDrivers puts it on the rim with its axis along the rim.  Brute force on the mesh's surface
points; the hole is the direction and place where the tube is widest while mesh surrounds it on all four sides."""
import numpy as np


def find_hole(pos, tris, avoid=None, ndir=500):
    P = np.vstack([pos, pos[tris].mean(1), (pos[tris[:, 0]] + pos[tris[:, 1]]) / 2, (pos[tris[:, 1]] + pos[tris[:, 2]]) / 2,
                   (pos[tris[:, 0]] + pos[tris[:, 2]]) / 2])
    c0 = pos.mean(0)
    i = np.arange(ndir) + 0.5
    phi, th = np.arccos(1 - 2 * i / ndir), np.pi * (1 + 5 ** 0.5) * i
    D = np.stack([np.cos(th) * np.sin(phi), np.sin(th) * np.sin(phi), np.cos(phi)], 1)
    grid = [np.array([a, b]) for a in np.linspace(-0.035, 0.035, 15) for b in np.linspace(-0.035, 0.035, 15)]
    best = (0, None, None)
    for d in D:
        if avoid is not None and abs(d @ avoid) > 0.6:
            continue      # along the forearm is not a grip
        a = np.cross(d, [0, 0, 1.0])
        if np.linalg.norm(a) < 1e-6:
            a = np.cross(d, [0, 1.0, 0])
        a /= np.linalg.norm(a)
        b = np.cross(d, a)
        q = np.stack([(P - c0) @ a, (P - c0) @ b], 1)
        for g in grid:
            dist = np.linalg.norm(q - g, axis=1)
            r0 = dist.min()
            if r0 <= best[0]:
                continue
            near = dist < r0 + 0.02
            if near.sum() < 30:
                continue
            ang = np.arctan2(q[near, 1] - g[1], q[near, 0] - g[0])
            if (np.histogram(ang, bins=4, range=(-np.pi, np.pi))[0] > 0).all():
                best = (r0, d.copy(), c0 + g[0] * a + g[1] * b)
    r0, d, c = best
    # the point on the axis nearest the middle of the hand's surface along it
    t = (P - c) @ d
    c = c + d * np.median(t[np.linalg.norm(P - c - np.outer(t, d), axis=1) < r0 + 0.02])
    return c, d, r0
