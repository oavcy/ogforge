// OGForge — OG image element templates
// Returns plain objects compatible with workers-og / satori

import type { OGParams } from '../types';

// Satori reads a *string* line-height as a raw pixel length: `lineHeight: 1.2`
// gives every line box a height of 1.2px, so a wrapped title prints all of its
// lines on top of one another and whatever follows lands in the same place.
// Only an unquoted number is treated as the usual font-size multiplier, so the
// type makes the quoted form a compile error rather than a rendering surprise.
type StyleObject = Record<string, string | number | undefined> & {
  lineHeight?: number;
};

type VNode = {
  type: string;
  props: {
    style?: StyleObject;
    children?: unknown;
    [key: string]: unknown;
  };
};

// A div that holds wrapping text is laid out as an explicit column; Satori's
// default row direction is the other half of the same overlap problem.
function textBlock(node: VNode): VNode {
  return {
    ...node,
    props: {
      ...node.props,
      style: { display: 'flex', flexDirection: 'column', ...node.props.style },
    },
  };
}

// Wraps the title and its description into a single centred column so the pair
// stays optically together no matter how tall the title wraps.
function ContentBlock(titleNode: VNode, descriptionNode?: VNode): VNode {
  const children = [textBlock(titleNode)];
  if (descriptionNode) children.push(textBlock(descriptionNode));

  return {
    type: 'div',
    props: {
      style: {
        display: 'flex',
        flexDirection: 'column',
        flex: '1',
        justifyContent: 'center',
        width: '100%',
      },
      children,
    },
  };
}

// Accent bar — left edge visual anchor.
// Anchored top *and* bottom rather than `height: 100%`: Satori resolves a
// percentage height against the parent's content box, so with 64px of vertical
// padding the bar stopped 128px short and read as a clipped graphic.
function AccentBar(color: string): VNode {
  return {
    type: 'div',
    props: {
      style: {
        position: 'absolute',
        top: '0',
        bottom: '0',
        left: '0',
        width: '6px',
        backgroundColor: color,
      },
      children: null,
    },
  };
}

// Header row: domain on left, tag pill on right
function Header(domain: string | undefined, tag: string | undefined, accent: string, surface: string, primary: string): VNode {
  return {
    type: 'div',
    props: {
      style: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        marginBottom: '48px',
        width: '100%',
      },
      children: [
        domain
          ? {
              type: 'div',
              props: {
                style: {
                  fontSize: '18px',
                  color: accent,
                  fontFamily: 'monospace',
                  letterSpacing: '0.06em',
                  textTransform: 'uppercase',
                },
                children: domain,
              },
            }
          : { type: 'div', props: { style: { width: '1px' }, children: null } },
        tag
          ? {
              type: 'div',
              props: {
                style: {
                  fontSize: '13px',
                  color: primary,
                  backgroundColor: surface,
                  padding: '6px 16px',
                  borderRadius: '100px',
                  fontFamily: 'monospace',
                  letterSpacing: '0.04em',
                },
                children: tag,
              },
            }
          : { type: 'div', props: { style: { width: '1px' }, children: null } },
      ],
    },
  };
}

// Footer row: author on left, watermark on right
function Footer(
  author: string | undefined,
  watermark: boolean,
  secondary: string
): VNode {
  return {
    type: 'div',
    props: {
      style: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        marginTop: '48px',
        width: '100%',
      },
      children: [
        author
          ? {
              type: 'div',
              props: {
                style: {
                  fontSize: '18px',
                  color: secondary,
                  fontFamily: 'monospace',
                },
                children: `— ${author}`,
              },
            }
          : { type: 'div', props: { style: { width: '1px' }, children: null } },
        watermark
          ? {
              type: 'div',
              props: {
                style: {
                  fontSize: '14px',
                  color: secondary,
                  fontFamily: 'monospace',
                  opacity: '0.55',
                  letterSpacing: '0.06em',
                },
                children: 'OGForge',
              },
            }
          : { type: 'div', props: { style: { width: '1px' }, children: null } },
      ],
    },
  };
}

// Default template — general purpose
function defaultTemplate(params: OGParams, watermark: boolean): VNode {
  const { title, description, domain, author, tag, theme = 'dark' } = params;
  const isDark = theme === 'dark';

  const bg = isDark ? '#0A0A0A' : '#FAFAFA';
  const primary = isDark ? '#F5F5F5' : '#0A0A0A';
  // Three steps, not two: headline, body, metadata. The description used to
  // share the metadata grey (~4.2:1 on this background), which is unreadable at
  // the thumbnail size a social card is actually seen at.
  const body = isDark ? '#A3A3A3' : '#52525B';
  const secondary = '#737373';
  const accent = '#F59E0B';
  const surface = isDark ? '#1A1A1A' : '#E8E8E8';

  const fontSize = title.length > 60 ? '42px' : title.length > 40 ? '52px' : '62px';

  return {
    type: 'div',
    props: {
      style: {
        display: 'flex',
        flexDirection: 'column',
        width: '100%',
        height: '100%',
        backgroundColor: bg,
        padding: '64px 72px 64px 84px',
        position: 'relative',
        fontFamily: '"Noto Sans", sans-serif',
      },
      children: [
        AccentBar(accent),
        Header(domain, tag, accent, surface, primary),
        // Title + description read as one optical block, vertically centred in
        // the space the header and footer leave behind. (Letting the title take
        // flex:1 on its own strands the description at the bottom edge.)
        ContentBlock(
          {
            type: 'div',
            props: {
              style: {
                display: 'flex',
                fontSize,
                fontWeight: '700',
                color: primary,
                lineHeight: 1.2,
                letterSpacing: '-0.02em',
              },
              children: title,
            },
          },
          description
            ? {
                type: 'div',
                props: {
                  style: {
                    display: 'flex',
                    fontSize: '22px',
                    color: body,
                    marginTop: '24px',
                    lineHeight: 1.5,
                    maxWidth: '900px',
                  },
                  children: description,
                },
              }
            : undefined
        ),
        Footer(author, watermark, secondary),
      ],
    },
  };
}

// Blog template — date-focused, editorial feel
function blogTemplate(params: OGParams, watermark: boolean): VNode {
  const { title, description, domain, author, tag, theme = 'dark' } = params;
  const isDark = theme === 'dark';

  const bg = isDark ? '#0D0D0D' : '#FFFFFF';
  const primary = isDark ? '#FAFAFA' : '#111111';
  const body = isDark ? '#9CA3AF' : '#4B5563';
  const secondary = '#6B7280';
  const accent = '#F59E0B';
  const surface = isDark ? '#1F1F1F' : '#F3F4F6';

  const fontSize = title.length > 55 ? '44px' : title.length > 35 ? '54px' : '64px';

  return {
    type: 'div',
    props: {
      style: {
        display: 'flex',
        flexDirection: 'column',
        width: '100%',
        height: '100%',
        backgroundColor: bg,
        padding: '72px 80px',
        position: 'relative',
        fontFamily: '"Noto Serif", serif',
      },
      children: [
        // Top band
        {
          type: 'div',
          props: {
            style: {
              position: 'absolute',
              top: '0',
              left: '0',
              right: '0',
              height: '4px',
              backgroundColor: accent,
            },
            children: null,
          },
        },
        // Site label + tag
        Header(domain, tag, accent, surface, primary),
        ContentBlock(
          {
            type: 'div',
            props: {
              style: {
                display: 'flex',
                fontSize,
                fontWeight: '700',
                color: primary,
                lineHeight: 1.2,
                letterSpacing: '-0.01em',
              },
              children: title,
            },
          },
          description
            ? {
                type: 'div',
                props: {
                  style: {
                    display: 'flex',
                    fontSize: '21px',
                    color: body,
                    marginTop: '28px',
                    lineHeight: 1.6,
                    // Capped like the other two templates: the full 1040px
                    // column runs ~105 characters a line, well past a readable
                    // measure. Headlines can span the width; body copy can't.
                    maxWidth: '880px',
                    fontStyle: 'italic',
                  },
                  children: description,
                },
              }
            : undefined
        ),
        Footer(author, watermark, secondary),
      ],
    },
  };
}

// Article template — minimal, high-contrast, magazine aesthetic
function articleTemplate(params: OGParams, watermark: boolean): VNode {
  const { title, description, domain, author, tag, theme = 'dark' } = params;
  const isDark = theme === 'dark';

  const bg = isDark ? '#111111' : '#F8F8F8';
  const primary = isDark ? '#FFFFFF' : '#111111';
  const secondary = isDark ? '#9CA3AF' : '#4B5563';
  const accent = '#F59E0B';
  const _surface = isDark ? '#222222' : '#E5E7EB';
  void _surface;
  const divider = isDark ? '#2A2A2A' : '#D1D5DB';

  const fontSize = title.length > 60 ? '40px' : title.length > 40 ? '50px' : '60px';

  return {
    type: 'div',
    props: {
      style: {
        display: 'flex',
        flexDirection: 'column',
        width: '100%',
        height: '100%',
        backgroundColor: bg,
        padding: '60px 72px',
        position: 'relative',
        fontFamily: '"Noto Sans", sans-serif',
      },
      children: [
        // Category row
        {
          type: 'div',
          props: {
            style: {
              display: 'flex',
              alignItems: 'center',
              gap: '12px',
              marginBottom: '32px',
            },
            children: [
              tag
                ? {
                    type: 'div',
                    props: {
                      style: {
                        fontSize: '12px',
                        fontWeight: '700',
                        color: accent,
                        letterSpacing: '0.12em',
                        textTransform: 'uppercase',
                        fontFamily: 'monospace',
                      },
                      children: tag,
                    },
                  }
                : { type: 'div', props: { style: { width: '1px' }, children: null } },
              domain
                ? {
                    type: 'div',
                    props: {
                      style: {
                        fontSize: '12px',
                        color: secondary,
                        letterSpacing: '0.08em',
                        textTransform: 'uppercase',
                        fontFamily: 'monospace',
                      },
                      children: `• ${domain}`,
                    },
                  }
                : { type: 'div', props: { style: { width: '1px' }, children: null } },
            ],
          },
        },
        // Divider
        {
          type: 'div',
          props: {
            style: {
              width: '48px',
              height: '3px',
              backgroundColor: accent,
              marginBottom: '32px',
            },
            children: null,
          },
        },
        ContentBlock(
          {
            type: 'div',
            props: {
              style: {
                display: 'flex',
                fontSize,
                fontWeight: '800',
                color: primary,
                lineHeight: 1.15,
                letterSpacing: '-0.025em',
              },
              children: title,
            },
          },
          description
            ? {
                type: 'div',
                props: {
                  style: {
                    display: 'flex',
                    fontSize: '20px',
                    color: secondary,
                    marginTop: '20px',
                    lineHeight: 1.5,
                    maxWidth: '850px',
                  },
                  children: description,
                },
              }
            : undefined
        ),
        // Footer divider + meta
        {
          type: 'div',
          props: {
            style: {
              width: '100%',
              height: '1px',
              backgroundColor: divider,
              marginTop: '36px',
            },
            children: null,
          },
        },
        {
          type: 'div',
          props: {
            style: {
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginTop: '16px',
              fontFamily: 'monospace',
            },
            children: [
              author
                ? {
                    type: 'div',
                    props: {
                      style: { fontSize: '16px', color: secondary },
                      children: author,
                    },
                  }
                : { type: 'div', props: { style: { width: '1px' }, children: null } },
              watermark
                ? {
                    type: 'div',
                    props: {
                      style: {
                        fontSize: '13px',
                        color: secondary,
                        opacity: '0.5',
                        letterSpacing: '0.06em',
                      },
                      children: 'OGForge',
                    },
                  }
                : { type: 'div', props: { style: { width: '1px' }, children: null } },
            ],
          },
        },
      ],
    },
  };
}

export function buildElement(params: OGParams, watermark: boolean): VNode {
  switch (params.template) {
    case 'blog':
      return blogTemplate(params, watermark);
    case 'article':
      return articleTemplate(params, watermark);
    default:
      return defaultTemplate(params, watermark);
  }
}
