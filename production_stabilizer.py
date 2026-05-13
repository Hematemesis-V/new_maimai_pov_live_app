import cv2
import time
import math
import struct
import socket
import threading
import queue
import numpy as np
import sounddevice as sd
import SpoutGL
import OpenGL.GL as gl
import torch
import torch.nn.functional as F
from ultralytics import YOLO

# ================================================================
# ⚙️ 全局参数化配置 (Production Config - Dual Lens System)
# tidevice relay 8080 8080
# ================================================================
CFG = {
    "network": {
        "host": "127.0.0.1",        
        "port": 8080,               
        "reconnect_delay": 2.0,     
        "recv_buf_size": 1 << 20,   
    },
    
    "resolution": {
        "nv12_w": 1440,             
        "nv12_h": 1920,             
        "stab_w": 1080,             
        "stab_h": 1440,             
        "yolo_in_size": 640,        
        "output_w": 720,            
        "output_h": 1280,           
    },
    
    "cameras": {
        "calib_base_width": 1440.0,
        
        "main": {
            "name": "Main (Full Frame)",
            "fx": 637.96525775, "fy": 637.53280269,
            "cx": 720.0,        "cy": 960.0,
            "k1": 0.14130226,   "k2": -0.07536199,
            "k3": 0.02657343,   "k4": -0.00507701,
            "default_fov": 100
        },

        "uw": {
            "name": "Ultra-Wide (Circular)",
            "fx": 375.5078, "fy": 375.7163,
            "cx": 715.9977,  "cy": 955.2196,
            "k1": 0.047681,  "k2": 0.005396,
            "k3": -0.006743, "k4": 0.000068,
            "default_fov": 145
        }
    },
    
    "yolo": {
        "model_path": r"D:\maimai\maimai_trae\runs\detect\maimai_bbox_v1\exp_4060ti\weights\best.engine",
        "inner_screen_class": 1,    
        "confidence_threshold": 0.8,
        "padding": 40,              
    },
    
    "tracking": {
        "alpha": 0.8,              
        "max_edge_speed": 15.0,     
        "inner_screen_ratio": 0.5,  
        "recenter_decay": 0.02,     
        "recenter_grace_sec": 0.5,  
    },
    
    "stabilizer": {
        "grid_ds": 10,              
    },
}

# ================================================================
# 📐 派生常量
# ================================================================
_NV12_W = CFG["resolution"]["nv12_w"]
_NV12_H = CFG["resolution"]["nv12_h"]
_STAB_W = CFG["resolution"]["stab_w"]
_STAB_H = CFG["resolution"]["stab_h"]
_YOLO_IN = CFG["resolution"]["yolo_in_size"]
_OUT_W = CFG["resolution"]["output_w"]
_OUT_H = CFG["resolution"]["output_h"]
_OUT_RATIO = _OUT_W / _OUT_H

PACK_HEADER = struct.Struct("<4sd4f4f4fI")
HEADER_SIZE = PACK_HEADER.size
EXPECTED_NV12 = _NV12_W * _NV12_H * 3 // 2

AUDIO_HEADER = struct.Struct("<dI")
AUDIO_HEADER_SIZE = AUDIO_HEADER.size

# ================================================================
# 🧠 CUDA 常驻显存池
# ================================================================
_NV12_CUDA_BUFFER = torch.empty(EXPECTED_NV12, dtype=torch.uint8, device="cuda")
_Y2R = torch.tensor([[1.0, 1.0, 1.0], [0.0, -0.344136, 1.772], [1.402, -0.714136, 0.0]], dtype=torch.float32, device="cuda")
_Q_CONJ = torch.tensor([1.0, -1.0, -1.0, -1.0], dtype=torch.float32, device="cuda")

# ================================================================
# 🧵 全局队列与共享状态
# ================================================================
frame_queue = queue.Queue(maxsize=1)
network_queue = queue.Queue(maxsize=3)
audio_queue = queue.Queue(maxsize=50)

shared_controls = {
    "gain": 1.0,
    "n_fps": 0.0,
    "t_alpha": 0.1,
    "t_speed": 5.0,
    "t_deadz": 8.0,
}

exit_flag = False
network_thread = None

# ================================================================
# 📦 共享裁剪状态
# ================================================================
class SharedCropState:
    def __init__(self, out_w, out_h):
        self.lock = threading.Lock()
        self.detected = False
        self.last_detect_time = 0.0
        self.cx = _STAB_W / 2.0
        self.cy = _STAB_H / 2.0
        self.target_ratio = out_w / out_h
        max_h = _STAB_H
        max_w = max_h * self.target_ratio
        if max_w > _STAB_W:
            max_h = _STAB_W / self.target_ratio
        self.crop_h = max_h
        self._update_corners()

    def _update_corners(self):
        crop_w = self.crop_h * self.target_ratio
        half_w = crop_w / 2.0
        half_h = self.crop_h / 2.0
        self.x1 = int(max(0, self.cx - half_w))
        self.y1 = int(max(0, self.cy - half_h))
        self.x2 = int(min(_STAB_W, self.cx + half_w))
        self.y2 = int(min(_STAB_H, self.cy + half_h))

    def set_crop(self, cx, cy, crop_h):
        with self.lock:
            self.cx = cx
            self.cy = cy
            self.crop_h = float(crop_h)
            self.detected = True
            self.last_detect_time = time.monotonic()
            self._update_corners()

    def recenter_step(self):
        with self.lock:
            if not self.detected:
                return
            elapsed = time.monotonic() - self.last_detect_time
            if elapsed < CFG["tracking"]["recenter_grace_sec"]:
                return
            decay = CFG["tracking"]["recenter_decay"]
            target_cx = _STAB_W / 2.0
            target_cy = _STAB_H / 2.0
            max_h = _STAB_H
            if max_h * self.target_ratio > _STAB_W:
                max_h = _STAB_W / self.target_ratio
            target_h = max_h
            self.cx += (target_cx - self.cx) * decay
            self.cy += (target_cy - self.cy) * decay
            self.crop_h += (target_h - self.crop_h) * decay
            self._update_corners()

    def get_crop(self):
        with self.lock:
            return self.x1, self.y1, self.x2, self.y2

    def get_ideal_params(self):
        with self.lock:
            return self.cx, self.cy, self.crop_h

shared_crop = SharedCropState(CFG["resolution"]["output_w"], CFG["resolution"]["output_h"])

# ================================================================
# 🔌 网络接收工具
# ================================================================
def recv_exact(sock, n):
    buf = bytearray(n)
    view = memoryview(buf)
    off = 0
    chunk_size = CFG["network"]["recv_buf_size"]
    while off < n:
        chunk = sock.recv_into(view[off:], min(n - off, chunk_size))
        if not chunk: raise ConnectionError("Connection closed")
        off += chunk
    return buf

@torch.inference_mode()
def jpeg_to_rgb_cuda(jpeg_raw, gain=1.0):
    img_np = cv2.imdecode(np.frombuffer(jpeg_raw, np.uint8), cv2.IMREAD_COLOR)
    if img_np is None:
        raise ValueError("JPEG 解码失败，可能是数据包残缺")
    
    img_rgb = cv2.cvtColor(img_np, cv2.COLOR_BGR2RGB)
    
    img_tensor = torch.from_numpy(img_rgb).cuda().float() / 255.0
    img_tensor = (img_tensor * gain).clamp(0, 1.0)
    
    rgb_portrait = torch.rot90(img_tensor, k=-1, dims=(0, 1))
    
    return rgb_portrait.permute(2, 0, 1).unsqueeze(0)

# ================================================================
# 🏗️ 动态光学引擎：带热切换的鱼眼防抖矫正器
# ================================================================
class ZeroCopyStabilizer:
    def __init__(self, in_h, in_w, out_h, out_w, grid_ds=10):
        self.device = "cuda"
        self.h_in, self.w_in = in_h, in_w
        self.h_out, self.w_out = out_h, out_w

        self.h_low = out_h // grid_ds
        self.w_low = out_w // grid_ds

        u, v = torch.meshgrid(
            torch.linspace(0, self.w_out - 1, self.w_low, device=self.device),
            torch.linspace(0, self.h_out - 1, self.h_low, device=self.device),
            indexing="xy",
        )
        self.x_s = u - self.w_out / 2.0
        self.y_s = v - self.h_out / 2.0
        r_s = torch.sqrt(self.x_s**2 + self.y_s**2)
        self.r_safe = torch.clamp(r_s, min=1e-5)
        self.r_norm = r_s / (self.w_out / 2.0)

        self.q_anchor = None
        self.rays_virtual_low = None
        self.rays_w_cache = None
        
        self.fx = self.fy = self.cx = self.cy = 0.0
        self.k1 = self.k2 = self.k3 = self.k4 = 0.0
        
        self.state = {"fov": -1, "dist": -1, "yaw": -999, "pitch": -999, "roll": -999, "lens": None}

    def load_lens(self, lens_key):
        if self.state["lens"] == lens_key: return
        
        cam = CFG["cameras"][lens_key]
        scale = _NV12_W / CFG["cameras"]["calib_base_width"]
        
        self.fx = cam["fx"] * scale
        self.fy = cam["fy"] * scale
        self.cx = cam["cx"] * scale
        self.cy = cam["cy"] * scale
        self.k1 = cam["k1"]
        self.k2 = cam["k2"]
        self.k3 = cam["k3"]
        self.k4 = cam["k4"]
        
        self.state["fov"] = -1
        self.state["lens"] = lens_key

    def set_anchor(self, q_list):
        self.q_anchor = F.normalize(torch.tensor(q_list, device=self.device).float(), dim=0)
        self.state["yaw"] = -999 

    def _update_view_cache(self, fov_deg, dist_ratio, yaw, pitch, roll):
        if (fov_deg == self.state["fov"] and dist_ratio == self.state["dist"] and
            yaw == self.state["yaw"] and pitch == self.state["pitch"] and roll == self.state["roll"] and
            self.rays_w_cache is not None):
            return

        if fov_deg != self.state["fov"] or dist_ratio != self.state["dist"]:
            fov_rad_half = math.radians(fov_deg / 2.0)
            theta_rect = torch.atan(self.r_norm * math.tan(fov_rad_half))
            theta_fish = self.r_norm * fov_rad_half
            theta = dist_ratio * theta_rect + (1.0 - dist_ratio) * theta_fish
            
            rz = torch.cos(theta)
            r_xy = torch.sin(theta)
            rx = r_xy * (self.x_s / self.r_safe)
            ry = r_xy * (self.y_s / self.r_safe)
            self.rays_virtual_low = torch.stack((rx, ry, rz), dim=-1)

        y_r, p_r, r_r = math.radians(yaw), math.radians(pitch), math.radians(roll)
        cy, sy = math.cos(y_r), math.sin(y_r)
        cp, sp = math.cos(p_r), math.sin(p_r)
        cr, sr = math.cos(r_r), math.sin(r_r)
        
        Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
        Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
        Rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
        R_view = Rz @ Ry @ Rx
        R_view_t = torch.from_numpy(R_view).float().to(self.device)

        rays_view_low = torch.matmul(self.rays_virtual_low, R_view_t.T)
        self.rays_w_cache = self._q_rot(self.q_anchor, rays_view_low)

        self.state.update({"fov": fov_deg, "dist": dist_ratio, "yaw": yaw, "pitch": pitch, "roll": roll})

    @staticmethod
    def _q_inv(q): return q * _Q_CONJ

    @staticmethod
    def _q_rot(q, v):
        a0, a1, a2 = q[..., 1], q[..., 2], q[..., 3]
        b0, b1, b2 = v[..., 0], v[..., 1], v[..., 2]
        c0, c1, c2 = a1 * b2 - a2 * b1, a2 * b0 - a0 * b2, a0 * b1 - a1 * b0
        t0, t1, t2 = c0 * 2, c1 * 2, c2 * 2
        d0, d1, d2 = a1 * t2 - a2 * t1, a2 * t0 - a0 * t2, a0 * t1 - a1 * t0
        w = q[..., 0]
        return torch.stack([b0 + w * t0 + d0, b1 + w * t1 + d1, b2 + w * t2 + d2], dim=-1)

    def _distort(self, rx, ry, rz):
        rxy = torch.sqrt(rx**2 + ry**2)
        th = torch.atan2(rxy, rz)
        t2 = th**2; t4 = t2**2; t6 = t4 * t2; t8 = t4**2
        th_p = th * (1 + self.k1 * t2 + self.k2 * t4 + self.k3 * t6 + self.k4 * t8)
        s = torch.where(rxy > 1e-5, th_p / rxy, torch.zeros_like(rxy))
        return rx * s, ry * s

    def _compute_grid_low(self, qt, qc, qb):
        rl = self._q_rot(self._q_inv(qc), self.rays_w_cache)
        xa, _ = self._distort(rl[..., 0], rl[..., 1], rl[..., 2])
        x_frac = torch.clamp((self.fx * xa + self.cx) / self.w_in, 0.0, 1.0).unsqueeze(-1)

        qp = F.normalize(qt * x_frac + qb * (1.0 - x_frac), p=2, dim=-1)

        rl2 = self._q_rot(self._q_inv(qp), self.rays_w_cache)
        xf, yf = self._distort(rl2[..., 0], rl2[..., 1], rl2[..., 2])

        mx = 2.0 * (self.fx * xf + self.cx) / (self.w_in - 1) - 1.0
        my = 2.0 * (self.fy * yf + self.cy) / (self.h_in - 1) - 1.0
        return torch.stack((mx, my), dim=-1).unsqueeze(0)

    @torch.inference_mode()
    def process_frame(self, rgb, q_center, q_top, q_bottom, yaw, pitch, roll, fov_deg, dist_ratio):
        if self.q_anchor is None:
            self.set_anchor(q_center)
            
        self._update_view_cache(fov_deg, dist_ratio, yaw, pitch, roll)

        qc = F.normalize(torch.tensor(q_center, device=self.device).float(), dim=0).view(1, 1, 4)
        qt = F.normalize(torch.tensor(q_top, device=self.device).float(), dim=0).view(1, 1, 4)
        qb = F.normalize(torch.tensor(q_bottom, device=self.device).float(), dim=0).view(1, 1, 4)

        grid_low = self._compute_grid_low(qt, qc, qb)
        grid_low_permuted = grid_low.permute(0, 3, 1, 2)
        grid_high_permuted = F.interpolate(grid_low_permuted, size=(self.h_out, self.w_out), mode="bilinear", align_corners=True)
        grid_high = grid_high_permuted.permute(0, 2, 3, 1)

        return F.grid_sample(rgb, grid_high, mode="bilinear", padding_mode="zeros", align_corners=True)

# ================================================================
# 🤖 YOLO 跟踪线程
# ================================================================
def yolo_inference_thread():
    model_path = CFG["yolo"]["model_path"]
    inner_cls = CFG["yolo"]["inner_screen_class"]
    conf_thresh = CFG["yolo"]["confidence_threshold"]
    alpha = CFG["tracking"]["alpha"]
    max_speed = CFG["tracking"]["max_edge_speed"]
    ratio = CFG["tracking"]["inner_screen_ratio"]
    pad = CFG["yolo"]["padding"]

    print(f"[YOLO] 正在加载 TensorRT 引擎: {model_path}")
    model = YOLO(model_path, task="detect")
    print("[YOLO] ✅ 引擎加载完成，AI 追踪启动！")

    smooth_x1 = smooth_y1 = smooth_x2 = smooth_y2 = None

    while True:
        try:
            item = frame_queue.get(block=True)
            if item is None: break
            tensor, scale, pad_left, pad_top = item

            results = model(tensor, verbose=False, device="cuda")
            detected = False
            
            if len(results[0].boxes) > 0:
                boxes = results[0].boxes.xyxy
                classes = results[0].boxes.cls
                confidences = results[0].boxes.conf

                for i in range(len(boxes)):
                    if int(classes[i]) == inner_cls and confidences[i] >= conf_thresh:
                        raw_x1, raw_y1, raw_x2, raw_y2 = boxes[i].cpu().numpy()

                        raw_x1 -= pad_left; raw_y1 -= pad_top
                        raw_x2 -= pad_left; raw_y2 -= pad_top
                        raw_x1 /= scale; raw_y1 /= scale
                        raw_x2 /= scale; raw_y2 /= scale
                        raw_x1 -= pad; raw_y1 -= pad
                        raw_x2 -= pad; raw_y2 -= pad

                        if smooth_x1 is None:
                            smooth_x1, smooth_y1 = raw_x1, raw_y1
                            smooth_x2, smooth_y2 = raw_x2, raw_y2
                        else:
                            current_alpha = shared_controls.get("t_alpha", 0.1)
                            current_max_speed = shared_controls.get("t_speed", 5.0)
                            current_deadzone = shared_controls.get("t_deadz", 8.0)

                            raw_cx = (raw_x1 + raw_x2) / 2.0
                            raw_cy = (raw_y1 + raw_y2) / 2.0
                            smooth_cx = (smooth_x1 + smooth_x2) / 2.0
                            smooth_cy = (smooth_y1 + smooth_y2) / 2.0
                            center_dist = math.hypot(raw_cx - smooth_cx, raw_cy - smooth_cy)

                            if center_dist > current_deadzone:
                                dx1 = np.clip(raw_x1 - smooth_x1, -current_max_speed, current_max_speed)
                                dy1 = np.clip(raw_y1 - smooth_y1, -current_max_speed, current_max_speed)
                                dx2 = np.clip(raw_x2 - smooth_x2, -current_max_speed, current_max_speed)
                                dy2 = np.clip(raw_y2 - smooth_y2, -current_max_speed, current_max_speed)
                            else:
                                dx1 = dy1 = dx2 = dy2 = 0.0

                            safe_x1, safe_y1 = smooth_x1 + dx1, smooth_y1 + dy1
                            safe_x2, safe_y2 = smooth_x2 + dx2, smooth_y2 + dy2

                            smooth_x1 = current_alpha * safe_x1 + (1 - current_alpha) * smooth_x1
                            smooth_y1 = current_alpha * safe_y1 + (1 - current_alpha) * smooth_y1
                            smooth_x2 = current_alpha * safe_x2 + (1 - current_alpha) * smooth_x2
                            smooth_y2 = current_alpha * safe_y2 + (1 - current_alpha) * smooth_y2

                        detected = True
                        break

            if detected:
                cx = (smooth_x1 + smooth_x2) / 2.0
                cy = (smooth_y1 + smooth_y2) / 2.0
                w = smooth_x2 - smooth_x1
                h = smooth_y2 - smooth_y1

                r = CFG["resolution"]["output_w"] / CFG["resolution"]["output_h"]
                margin = CFG["tracking"]["inner_screen_ratio"]
                base_h = max(h, w / r)
                crop_h = base_h / margin
                shared_crop.set_crop(cx, cy, crop_h)
            else:
                shared_crop.recenter_step()

        except Exception as e:
            print(f"\n[YOLO Thread Error] {e}")
            time.sleep(0.1)

# ================================================================
# 📡 网络接收线程 (生产者)
# ================================================================
def network_receiver_thread():
    global exit_flag
    host = CFG["network"]["host"]
    port = CFG["network"]["port"]
    reconnect_delay = CFG["network"]["reconnect_delay"]

    n_cnt = 0
    n_t = time.perf_counter()
    
    bytes_recv = 0
    bw_t = time.perf_counter()

    while not exit_flag:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        
        try:
            sock.connect((host, port))
            print(f"[TCP] ✅ 已连接 {host}:{port}")
        except OSError as e:
            print(f"[TCP] ❌ 网络错误: {e}，{reconnect_delay}s 后重试...")
            time.sleep(reconnect_delay)
            continue

        try:
            while not exit_flag:
                magic = recv_exact(sock, 4)
                bytes_recv += 4

                if magic == b"SYNC":
                    hdr_rest = recv_exact(sock, HEADER_SIZE - 4)
                    bytes_recv += HEADER_SIZE - 4

                    hdr_full = magic + hdr_rest
                    fields = PACK_HEADER.unpack(hdr_full)

                    nv12_size = fields[14]
                    nv12_raw = recv_exact(sock, nv12_size)
                    bytes_recv += nv12_size

                    now = time.perf_counter()
                    if now - bw_t >= 1.0:
                        mbps = (bytes_recv * 8) / (1024 * 1024)
                        mb_s = bytes_recv / (1024 * 1024)

                        shared_controls["mbps"] = mbps
                        shared_controls["mb_s"] = mb_s

                        bytes_recv = 0
                        bw_t = now

                    gain_val = shared_controls["gain"]
                    rgb = jpeg_to_rgb_cuda(nv12_raw, gain=gain_val)

                    if network_queue.full():
                        try:
                            network_queue.get_nowait()
                        except queue.Empty:
                            pass

                    network_queue.put((rgb, fields))

                    n_cnt += 1
                    if now - n_t >= 1.0:
                        shared_controls["n_fps"] = n_cnt / (now - n_t)
                        n_cnt = 0
                        n_t = now

                elif magic == b"AUDA":
                    audio_hdr = recv_exact(sock, AUDIO_HEADER_SIZE)
                    bytes_recv += AUDIO_HEADER_SIZE

                    timestamp, audio_size = AUDIO_HEADER.unpack(audio_hdr)
                    audio_raw = recv_exact(sock, audio_size)
                    bytes_recv += audio_size

                    if audio_queue.full():
                        try:
                            audio_queue.get_nowait()
                        except queue.Empty:
                            pass

                    audio_queue.put((timestamp, audio_raw))

                else:
                    continue

        except (ConnectionError, OSError) as e:
            print(f"\n[TCP] ⚠️ 连接断开: {e}，{reconnect_delay}s 后重连...")
        except Exception as e:
            print(f"\n[Network Thread Error] {e}")
        finally:
            try:
                sock.close()
            except Exception:
                pass

        time.sleep(reconnect_delay)

# ================================================================
# � 音频播放线程
# ================================================================
def audio_playback_thread():
    SAMPLE_RATE = 44100
    CHANNELS = 1

    target_device_id = None
    try:
        devices = sd.query_devices()
        for i, dev in enumerate(devices):
            if "CABLE Input" in dev['name'] and dev['max_output_channels'] > 0:
                target_device_id = i
                print(f"[Audio] 🎯 锁定虚拟声卡: {dev['name']} (ID: {i})")
                break
    except Exception as e:
        print(f"[Audio] ⚠️ 获取音频设备列表失败: {e}")

    if target_device_id is None:
        print("[Audio] ⚠️ 未找到 'CABLE Input' 虚拟声卡，回退到系统默认播放设备！请确认已安装 VB-Cable。")

    try:
        stream = sd.OutputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="int16",
            latency=0.05,
            device=target_device_id
        )
        stream.start()
        dev_name = target_device_id if target_device_id is not None else "System Default"
        print(f"[Audio] ✅ 音频播放流已启动 (Device: {dev_name})")
    except Exception as e:
        print(f"[Audio] ❌ 音频流初始化失败: {e}")
        return

    while not exit_flag:
        try:
            timestamp, audio_raw = audio_queue.get(timeout=1.0)
            audio_np = np.frombuffer(audio_raw, dtype=np.int16)
            if CHANNELS == 1 and audio_np.ndim == 1:
                audio_np = audio_np.reshape(-1, 1)
            try:
                stream.write(audio_np)
            except Exception as e:
                print(f"[Audio] 写入错误: {e}")
        except queue.Empty:
            continue
        except Exception as e:
            print(f"[Audio] 播放错误: {e}")
            time.sleep(0.01)

    try:
        stream.stop()
        stream.close()
    except Exception:
        pass

# ================================================================
# � 辅助函数
# ================================================================
def _qmul(a, b):
    return [
        a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
        a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
        a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
        a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0],
    ]

_DEV_TO_CAM = [0.0, 1.0, 0.0, 0.0]
_DEV_TO_CAM_INV = [0.0, -1.0, 0.0, 0.0]

def align_imu(q):
    q_cam = _qmul(_qmul(_DEV_TO_CAM, q), _DEV_TO_CAM_INV)
    norm = math.sqrt(sum(c * c for c in q_cam))
    return [c / norm for c in q_cam]

def nothing(x): pass

def init_trackbars(window_name, default_fov):
    cv2.createTrackbar('Stab', window_name, 1, 1, nothing)
    cv2.createTrackbar('Track', window_name, 1, 1, nothing)
    cv2.createTrackbar('Gain', window_name, 10, 50, nothing)
    cv2.createTrackbar('Yaw', window_name, 90, 180, nothing)     
    cv2.createTrackbar('Pitch', window_name, 90, 180, nothing)   
    cv2.createTrackbar('Roll', window_name, 90, 180, nothing)    
    cv2.createTrackbar('FOV', window_name, default_fov, 160, nothing)    
    cv2.createTrackbar('Distort', window_name, 100, 100, nothing)
    cv2.createTrackbar('T_Alpha', window_name, 10, 100, nothing)
    cv2.createTrackbar('T_Speed', window_name, 5, 50, nothing)
    cv2.createTrackbar('T_DeadZ', window_name, 8, 50, nothing) 

# ================================================================
# 🎮 主渲染循环 (消费者)
# ================================================================
def main():
    global exit_flag, network_thread

    output_w = CFG["resolution"]["output_w"]
    output_h = CFG["resolution"]["output_h"]

    stab = ZeroCopyStabilizer(_NV12_H, _NV12_W, _STAB_H, _STAB_W, grid_ds=CFG["stabilizer"]["grid_ds"])
    
    active_lens_key = "main"
    stab.load_lens(active_lens_key)

    yolo_t = threading.Thread(target=yolo_inference_thread, daemon=True)
    yolo_t.start()

    network_thread = threading.Thread(target=network_receiver_thread, daemon=True)
    network_thread.start()

    audio_thread = threading.Thread(target=audio_playback_thread, daemon=True)
    audio_thread.start()

    CONTROL_WINDOW = "Live Control Panel"

    cv2.namedWindow(CONTROL_WINDOW, cv2.WINDOW_AUTOSIZE)
    init_trackbars(CONTROL_WINDOW, CFG["cameras"][active_lens_key]["default_fov"])

    sender = SpoutGL.SpoutSender()
    sender.setSenderName("Maimai_POV")
    print("[Spout2] ✅ 视频直通通道已建立，等待 OBS 抓取...")

    g_cnt = 0
    g_t = time.perf_counter()
    g_fps = 0.0

    while True:
        try:
            rgb, fields = network_queue.get(timeout=1.0)
        except queue.Empty:
            key = cv2.waitKey(1) & 0xFF
            if key == ord("q"):
                break
            continue

        yaw = cv2.getTrackbarPos('Yaw', CONTROL_WINDOW) - 90
        pitch = cv2.getTrackbarPos('Pitch', CONTROL_WINDOW) - 90
        roll = cv2.getTrackbarPos('Roll', CONTROL_WINDOW) - 90
        fov = max(10, cv2.getTrackbarPos('FOV', CONTROL_WINDOW))
        dist_ratio = cv2.getTrackbarPos('Distort', CONTROL_WINDOW) / 100.0
        
        gain_val = cv2.getTrackbarPos('Gain', CONTROL_WINDOW) / 10.0
        shared_controls["gain"] = gain_val
        shared_controls["t_alpha"] = max(1, cv2.getTrackbarPos('T_Alpha', CONTROL_WINDOW)) / 100.0
        shared_controls["t_speed"] = float(max(1, cv2.getTrackbarPos('T_Speed', CONTROL_WINDOW)))
        shared_controls["t_deadz"] = float(cv2.getTrackbarPos('T_DeadZ', CONTROL_WINDOW))

        q_top = align_imu(fields[2:6])
        q_center = align_imu(fields[6:10])
        q_bottom = align_imu(fields[10:14])

        stab_on = cv2.getTrackbarPos('Stab', CONTROL_WINDOW) == 1
        track_on = stab_on and cv2.getTrackbarPos('Track', CONTROL_WINDOW) == 1

        if stab_on:
            out = stab.process_frame(rgb, q_center, q_top, q_bottom, yaw, pitch, roll, fov, dist_ratio)
        else:
            out = rgb

        if track_on and frame_queue.empty():
            pad = CFG["yolo"]["padding"]
            padded = F.pad(out, (pad, pad, pad, pad), value=0.0)
            _, _, ph, pw = padded.shape
            scale = min(_YOLO_IN / pw, _YOLO_IN / ph)
            new_w = int(pw * scale)
            new_h = int(ph * scale)
            resized = F.interpolate(padded, size=(new_h, new_w), mode="bilinear", align_corners=False)
            pad_left = (_YOLO_IN - new_w) // 2
            pad_top = (_YOLO_IN - new_h) // 2
            pad_right = _YOLO_IN - new_w - pad_left
            pad_bottom = _YOLO_IN - new_h - pad_top
            yolo_input = F.pad(resized, (pad_left, pad_right, pad_top, pad_bottom), value=0.0)
            frame_queue.put((yolo_input, scale, pad_left, pad_top))

        output_w = CFG["resolution"]["output_w"]
        output_h = CFG["resolution"]["output_h"]
        r = output_w / output_h
        
        if stab_on:
            if track_on:
                cx, cy, crop_h = shared_crop.get_ideal_params()
            else:
                cx, cy = _STAB_W / 2.0, _STAB_H / 2.0
                crop_h = _STAB_H
                if crop_h * r > _STAB_W:
                    crop_h = _STAB_W / r
            crop_w = crop_h * r
            half_w = crop_w / 2.0
            half_h = crop_h / 2.0
            x1 = int(max(0, cx - half_w))
            y1 = int(max(0, cy - half_h))
            x2 = int(min(_STAB_W, cx + half_w))
            y2 = int(min(_STAB_H, cy + half_h))

            if x2 > x1 and y2 > y1:
                cropped = out[:, :, y1:y2, x1:x2]
            else:
                cropped = out

            pad_left = np.clip(x1 - int(cx - half_w), 0, None)
            pad_right = np.clip(int(cx + half_w) - x2, 0, None)
            pad_top = np.clip(y1 - int(cy - half_h), 0, None)
            pad_bottom = np.clip(int(cy + half_h) - y2, 0, None)
            if pad_left > 0 or pad_right > 0 or pad_top > 0 or pad_bottom > 0:
                cropped = F.pad(cropped, (pad_left, pad_right, pad_top, pad_bottom), value=0.0)

            out_final = F.interpolate(cropped, size=(output_h, output_w), mode="bilinear", align_corners=False)
        else:
            crop_h = _STAB_H
            crop_w = crop_h * r
            x_off = int((_STAB_W - crop_w) / 2)
            cropped = out[:, :, 0:_STAB_H, x_off:x_off+int(crop_w)]
            out_final = F.interpolate(cropped, size=(output_h, output_w), mode="bilinear", align_corners=False)

        out_uint8 = (out_final.squeeze(0) * 255.0).clamp(0, 255).byte()
        out_rgb_np = out_uint8.permute(1, 2, 0).contiguous().cpu().numpy()
        sender.sendImage(out_rgb_np, output_w, output_h, gl.GL_RGB, False, 0)

        g_cnt += 1
        now = time.perf_counter()
        if now - g_t >= 1.0:
            g_fps = g_cnt / (now - g_t)
            g_cnt = 0
            g_t = now

        n_fps = shared_controls["n_fps"]

        if stab_on:
            if track_on:
                cx, cy, crop_h = shared_crop.get_ideal_params()
            else:
                cx, cy = _STAB_W / 2.0, _STAB_H / 2.0
                crop_h = _STAB_H
                if crop_h * r > _STAB_W:
                    crop_h = _STAB_W / r
            crop_w = crop_h * r
        else:
            cx, cy = _STAB_W / 2.0, _STAB_H / 2.0
            crop_h = _STAB_H
            crop_w = crop_h * r

        control_panel = np.zeros((360, 500, 3), dtype=np.uint8)
        lens_name = CFG["cameras"][active_lens_key]["name"]
        
        mbps = shared_controls.get("mbps", 0.0)
        mb_s = shared_controls.get("mb_s", 0.0)
        
        cv2.putText(control_panel, f"Net: {n_fps:.1f} FPS | GPU: {g_fps:.1f} FPS", (20, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
        cv2.putText(control_panel, f"Bandwidth: {mbps:.1f} Mbps ({mb_s:.1f} MB/s)", (20, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 165, 255), 2)
        cv2.putText(control_panel, f"Lens: {lens_name}", (20, 110), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 255), 2)
        cv2.putText(control_panel, "[Press 'S' to Hot-Swap Lens]", (20, 140), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (100, 100, 255), 1)
        
        cv2.putText(control_panel, f"Stab: {'ON' if stab_on else 'OFF'}  Track: {'ON' if track_on else 'OFF'}", (20, 180), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255) if stab_on else (100, 100, 100), 2)
        cv2.putText(control_panel, f"Y:{yaw} P:{pitch} R:{roll}", (20, 220), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 165, 255), 2)
        cv2.putText(control_panel, f"FOV:{fov} Dist:{dist_ratio:.2f}", (20, 260), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 165, 255), 2)
        cv2.putText(control_panel, f"Crop: ({cx:.0f},{cy:.0f}) WxH: {crop_w:.0f}x{crop_h:.0f}", (20, 300), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)
        cv2.putText(control_panel, f"Track Param -> Alpha: {shared_controls['t_alpha']:.2f} Spd: {shared_controls['t_speed']:.1f} DZ: {shared_controls['t_deadz']:.1f}", (20, 340), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (100, 255, 100), 1)
        
        cv2.imshow(CONTROL_WINDOW, control_panel)

        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        elif key == ord("s"):
            active_lens_key = "uw" if active_lens_key == "main" else "main"
            print(f"\n[Lens Swap] 切换至镜头: {CFG['cameras'][active_lens_key]['name']}")
            stab.load_lens(active_lens_key)
            cv2.setTrackbarPos('FOV', CONTROL_WINDOW, CFG["cameras"][active_lens_key]["default_fov"])

    exit_flag = True
    frame_queue.put(None)
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
